using System.Collections.Concurrent;
using Microsoft.Extensions.Options;
using Nocturne.API.Helpers;
using Nocturne.API.Multitenancy;
using Nocturne.API.Services.Identity;
using Nocturne.Core.Contracts.Auth;
using Nocturne.Core.Contracts.Multitenancy;
using Nocturne.Core.Models.Authorization;
using Nocturne.Infrastructure.Data.Services;

namespace Nocturne.API.Services.Migration;

/// <summary>
/// Moves many Nightscout users onto this instance in one go: for each user it checks their
/// MongoDB database, creates a tenant with a credential-less owner, then runs the ordinary
/// single-tenant MongoDB migration (<see cref="IMigrationJobService"/>) into it.
/// </summary>
public interface IBatchMigrationService
{
    /// <summary>Checks a batch's rows without creating anything.</summary>
    Task<BatchMigrationValidationResult> ValidateAsync(
        StartBatchMigrationRequest request, ITenantService tenants, CancellationToken ct = default);

    /// <summary>Starts a batch that has passed <see cref="ValidateAsync"/>.</summary>
    /// <exception cref="ArgumentException">The batch fails validation.</exception>
    Task<BatchMigrationStatus> StartAsync(
        StartBatchMigrationRequest request, ITenantService tenants, CancellationToken ct = default);

    BatchMigrationStatus? GetStatus(Guid batchId);

    IReadOnlyList<BatchMigrationSummary> List();

    /// <summary>Stops queued users from starting and cancels the imports in flight.</summary>
    /// <returns>False when no batch has that id.</returns>
    Task<bool> CancelAsync(Guid batchId);
}

/// <summary>
/// Implements <see cref="IBatchMigrationService"/>. Batches are held in memory: an API restart
/// forgets them, though every tenant created and every migration run started stays, and each
/// tenant's own migration history still records its import.
/// </summary>
/// <remarks>
/// Connection strings live only on the queued row and are dropped once that user's migration has
/// started; no status read returns them.
/// </remarks>
public sealed class BatchMigrationService : IBatchMigrationService
{
    internal const string Actor = "batch-migration";

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    private readonly IServiceScopeFactory _scopes;
    private readonly IMigrationJobService _migrations;
    private readonly BaseDomainOptions _baseDomain;
    private readonly TimeProvider _time;
    private readonly ILogger<BatchMigrationService> _logger;
    private readonly ConcurrentDictionary<Guid, Batch> _batches = new();

    public BatchMigrationService(
        IServiceScopeFactory scopes,
        IMigrationJobService migrations,
        IOptions<BaseDomainOptions> baseDomain,
        TimeProvider time,
        ILogger<BatchMigrationService> logger)
    {
        _scopes = scopes;
        _migrations = migrations;
        _baseDomain = baseDomain.Value;
        _time = time;
        _logger = logger;
    }

    public async Task<BatchMigrationValidationResult> ValidateAsync(
        StartBatchMigrationRequest request, ITenantService tenants, CancellationToken ct = default)
    {
        var errors = new List<BatchMigrationValidationError>();

        if (request.Users.Count == 0)
            errors.Add(new(-1, null, "Add at least one user."));

        if (request.Users.Count > BatchMigrationLimits.MaxUsers)
            errors.Add(new(-1, null, $"A batch holds at most {BatchMigrationLimits.MaxUsers} users."));

        if (request.MaxConcurrency is { } concurrency
            && (concurrency < 1 || concurrency > BatchMigrationLimits.MaxConcurrency))
            errors.Add(new(-1, null,
                $"Concurrency must be between 1 and {BatchMigrationLimits.MaxConcurrency}."));

        if (request.StartDate is { } from && request.EndDate is { } to && from > to)
            errors.Add(new(-1, null, "The start date is after the end date."));

        if (errors.Count > 0)
            return new BatchMigrationValidationResult { IsValid = false, Errors = errors };

        var seenSlugs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < request.Users.Count; i++)
        {
            var user = request.Users[i];
            var slug = user.Slug?.Trim().ToLowerInvariant() ?? "";

            if (string.IsNullOrEmpty(slug))
            {
                errors.Add(new(i, null, "A subdomain is required."));
                continue;
            }

            if (!seenSlugs.Add(slug))
            {
                errors.Add(new(i, slug, "This subdomain appears more than once in the batch."));
                continue;
            }

            var slugCheck = await tenants.ValidateSlugAsync(slug, ct);
            if (!slugCheck.IsValid)
                errors.Add(new(i, slug, slugCheck.Message ?? "This subdomain cannot be used."));

            if (string.IsNullOrWhiteSpace(user.DisplayName))
                errors.Add(new(i, slug, "A display name is required."));

            var username = UsernameRules.Normalize(
                string.IsNullOrWhiteSpace(user.OwnerUsername) ? slug : user.OwnerUsername);
            if (UsernameRules.Refusal(username) is { } usernameRefusal)
                errors.Add(new(i, slug, $"Username: {usernameRefusal}"));

            if (string.IsNullOrWhiteSpace(user.MongoDatabaseName))
                errors.Add(new(i, slug, "A MongoDB database name is required."));

            if (string.IsNullOrWhiteSpace(user.MongoConnectionString)
                && string.IsNullOrWhiteSpace(request.DefaultMongoConnectionString))
                errors.Add(new(i, slug,
                    "A MongoDB connection string is required, on the row or as the batch default."));
        }

        return new BatchMigrationValidationResult { IsValid = errors.Count == 0, Errors = errors };
    }

    public async Task<BatchMigrationStatus> StartAsync(
        StartBatchMigrationRequest request, ITenantService tenants, CancellationToken ct = default)
    {
        var validation = await ValidateAsync(request, tenants, ct);
        if (!validation.IsValid)
            throw new ArgumentException(string.Join(" ", validation.Errors.Select(e =>
                e.Index < 0 ? e.Message : $"Row {e.Index + 1} ({e.Slug}): {e.Message}")));

        var rows = request.Users.Select((u, i) =>
        {
            var slug = u.Slug.Trim().ToLowerInvariant();
            return new Row(
                i,
                slug,
                u.DisplayName.Trim(),
                UsernameRules.Normalize(string.IsNullOrWhiteSpace(u.OwnerUsername) ? slug : u.OwnerUsername),
                string.IsNullOrWhiteSpace(u.OwnerEmail) ? null : u.OwnerEmail.Trim(),
                u.MongoDatabaseName.Trim(),
                (string.IsNullOrWhiteSpace(u.MongoConnectionString)
                    ? request.DefaultMongoConnectionString!
                    : u.MongoConnectionString).Trim(),
                _baseDomain.TenantOrigin(slug));
        }).ToList();

        var batch = new Batch(
            Guid.CreateVersion7(),
            _time.GetUtcNow().UtcDateTime,
            request.MaxConcurrency ?? BatchMigrationLimits.DefaultConcurrency,
            request.Collections,
            request.StartDate,
            request.EndDate,
            rows);

        _batches[batch.Id] = batch;

        _logger.LogInformation(
            "Starting batch migration {BatchId} of {Count} users, {Concurrency} at a time",
            batch.Id, rows.Count, batch.MaxConcurrency);

        // Detached from the request on purpose: the batch outlives the call that started it, and
        // is stopped through its own token (CancelAsync).
        _ = Task.Run(() => RunAsync(batch), CancellationToken.None);

        return batch.Snapshot();
    }

    public BatchMigrationStatus? GetStatus(Guid batchId) =>
        _batches.TryGetValue(batchId, out var batch) ? batch.Snapshot() : null;

    public IReadOnlyList<BatchMigrationSummary> List() =>
        _batches.Values
            .Select(b => b.Snapshot())
            .OrderByDescending(s => s.CreatedAt)
            .Select(s => new BatchMigrationSummary(
                s.Id, s.CreatedAt, s.CompletedAt, s.IsRunning, s.Total, s.CompletedCount, s.FailedCount))
            .ToList();

    public async Task<bool> CancelAsync(Guid batchId)
    {
        if (!_batches.TryGetValue(batchId, out var batch))
            return false;

        await batch.Cancellation.CancelAsync();

        foreach (var row in batch.Rows)
        {
            var (tenantId, jobId) = row.MigrationHandle();
            if (tenantId is { } t && jobId is { } j)
            {
                try
                {
                    await _migrations.CancelAsync(t, j);
                }
                catch (KeyNotFoundException)
                {
                    // Already gone; nothing to stop.
                }
            }
        }

        _logger.LogInformation("Cancelled batch migration {BatchId}", batchId);
        return true;
    }

    private async Task RunAsync(Batch batch)
    {
        using var slots = new SemaphoreSlim(batch.MaxConcurrency);
        var ct = batch.Cancellation.Token;

        var work = batch.Rows.Select(async row =>
        {
            try
            {
                await slots.WaitAsync(ct);
            }
            catch (OperationCanceledException)
            {
                row.Cancel();
                return;
            }

            try
            {
                await RunRowAsync(batch, row, ct);
            }
            finally
            {
                slots.Release();
            }
        });

        await Task.WhenAll(work);
        batch.Finish(_time.GetUtcNow().UtcDateTime);

        var done = batch.Snapshot();
        _logger.LogInformation(
            "Batch migration {BatchId} finished: {Completed} completed, {Failed} failed of {Total}",
            batch.Id, done.CompletedCount, done.FailedCount, done.Total);
    }

    private async Task RunRowAsync(Batch batch, Row row, CancellationToken ct)
    {
        try
        {
            ct.ThrowIfCancellationRequested();

            // 1. Can the source be read? Checked before anything is created, so a typo in a
            //    database name leaves no empty tenant behind.
            row.Set(BatchMigrationUserState.TestingConnection, "Checking the MongoDB database");
            var test = await _migrations.TestConnectionAsync(new TestMigrationConnectionRequest
            {
                Mode = MigrationMode.MongoDb,
                MongoConnectionString = row.ConnectionString,
                MongoDatabaseName = row.DatabaseName,
            }, ct);

            if (!test.IsSuccess)
            {
                row.Fail($"Could not read the MongoDB database: {test.ErrorMessage}");
                return;
            }

            row.RecordSourceCounts(test.EntryCount, test.TreatmentCount);
            ct.ThrowIfCancellationRequested();

            // 2. The tenant and its owner. The owner holds no credential yet: the operator hands
            //    them a recovery link to enrol a passkey (see BatchMigrationController.ClaimLinks).
            row.Set(BatchMigrationUserState.Provisioning, "Creating the site and its owner");
            var (tenantId, subjectId) = await ProvisionAsync(row, ct);
            row.Provisioned(tenantId, subjectId);

            // 3. The import, through the same job a single tenant's migration runs.
            row.Set(BatchMigrationUserState.Migrating, "Starting the import");
            var job = await _migrations.StartMigrationAsync(
                new StartMigrationRequest
                {
                    Mode = MigrationMode.MongoDb,
                    MongoConnectionString = row.ConnectionString,
                    MongoDatabaseName = row.DatabaseName,
                    Collections = batch.Collections,
                    StartDate = batch.StartDate,
                    EndDate = batch.EndDate,
                },
                new TenantContext(tenantId, row.Slug, row.DisplayName, IsActive: true, IsDemo: false),
                ct);

            row.Started(job.Id);

            // 4. Hold the slot until the import ends, so the concurrency bound covers the imports
            //    themselves and not only their starts.
            while (true)
            {
                await Task.Delay(PollInterval, CancellationToken.None);

                MigrationJobStatus status;
                try
                {
                    status = await _migrations.GetStatusAsync(tenantId, job.Id);
                }
                catch (KeyNotFoundException)
                {
                    row.Fail("The migration job could not be found.");
                    return;
                }

                row.Progress(status.ProgressPercentage, status.CurrentOperation);

                if (status.State.IsLive())
                    continue;

                switch (status.State)
                {
                    case MigrationJobState.Completed:
                        row.Complete(status.HasFailures
                            ? "Imported, but some records could not be. See the site's migration history."
                            : null);
                        break;
                    case MigrationJobState.Cancelled:
                        row.Cancel();
                        break;
                    default:
                        row.Fail(status.ErrorMessage ?? $"The import ended as {status.State}.");
                        break;
                }

                return;
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            row.Cancel();
        }
        catch (MigrationAlreadyRunningException)
        {
            row.Fail("A migration is already running for this site.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Batch migration {BatchId}: user {Slug} failed",
                batch.Id, LogText.Sanitize(row.Slug));
            row.Fail(ex.Message);
        }
    }

    private async Task<(Guid TenantId, Guid SubjectId)> ProvisionAsync(Row row, CancellationToken ct)
    {
        await using var scope = TenantJobScope.Open(_scopes, null, Actor);
        var tenants = scope.ServiceProvider.GetRequiredService<ITenantService>();
        var subjects = scope.ServiceProvider.GetRequiredService<ISubjectRepository>();

        // Checked again: the subdomain may have been taken since the batch was validated.
        var slugCheck = await tenants.ValidateSlugAsync(row.Slug, ct);
        if (!slugCheck.IsValid)
            throw new InvalidOperationException(slugCheck.Message ?? "This subdomain cannot be used.");

        var subjectId = await subjects.CreateAsync(
            new NewSubject(row.DisplayName, Username: row.OwnerUsername, Email: row.OwnerEmail), ct);

        try
        {
            var tenant = await tenants.CreateWithOwnerAsync(
                row.Slug, row.DisplayName, subjectId, row.OwnerUsername, ct);
            return (tenant.Id, subjectId);
        }
        catch
        {
            // Leave no account behind that belongs to no site.
            try
            {
                await subjects.DeleteAsync(subjectId, CancellationToken.None);
            }
            catch (Exception cleanup)
            {
                _logger.LogWarning(cleanup, "Could not remove subject {SubjectId} after a failed provision", subjectId);
            }

            throw;
        }
    }

    private sealed class Batch(
        Guid id,
        DateTime createdAt,
        int maxConcurrency,
        List<string> collections,
        DateTime? startDate,
        DateTime? endDate,
        List<Row> rows)
    {
        private DateTime? _completedAt;

        public Guid Id { get; } = id;
        public int MaxConcurrency { get; } = maxConcurrency;
        public List<string> Collections { get; } = collections;
        public DateTime? StartDate { get; } = startDate;
        public DateTime? EndDate { get; } = endDate;
        public List<Row> Rows { get; } = rows;
        public CancellationTokenSource Cancellation { get; } = new();

        public void Finish(DateTime at) => _completedAt = at;

        public BatchMigrationStatus Snapshot()
        {
            var users = Rows.Select(r => r.Snapshot()).ToList();
            return new BatchMigrationStatus
            {
                Id = Id,
                CreatedAt = createdAt,
                CompletedAt = _completedAt,
                IsRunning = _completedAt is null,
                MaxConcurrency = MaxConcurrency,
                Total = users.Count,
                CompletedCount = users.Count(u => u.State == BatchMigrationUserState.Completed),
                FailedCount = users.Count(u => u.State == BatchMigrationUserState.Failed),
                Users = users,
            };
        }
    }

    private sealed class Row(
        int index,
        string slug,
        string displayName,
        string ownerUsername,
        string? ownerEmail,
        string databaseName,
        string connectionString,
        string? tenantUrl)
    {
        private readonly Lock _lock = new();
        private BatchMigrationUserState _state = BatchMigrationUserState.Queued;
        private string? _error;
        private string? _operation;
        private double _progress;
        private Guid? _tenantId;
        private Guid? _subjectId;
        private Guid? _jobId;
        private long? _entries;
        private long? _treatments;
        private string? _connectionString = connectionString;

        public string Slug { get; } = slug;
        public string DisplayName { get; } = displayName;
        public string OwnerUsername { get; } = ownerUsername;
        public string? OwnerEmail { get; } = ownerEmail;
        public string DatabaseName { get; } = databaseName;

        public string ConnectionString
        {
            get { lock (_lock) return _connectionString ?? throw new InvalidOperationException("Connection string already released."); }
        }

        public void Set(BatchMigrationUserState state, string operation)
        {
            lock (_lock) { _state = state; _operation = operation; }
        }

        public void RecordSourceCounts(long? entries, long? treatments)
        {
            lock (_lock) { _entries = entries; _treatments = treatments; }
        }

        public void Provisioned(Guid tenantId, Guid subjectId)
        {
            lock (_lock) { _tenantId = tenantId; _subjectId = subjectId; }
        }

        public void Started(Guid jobId)
        {
            lock (_lock) { _jobId = jobId; _connectionString = null; }
        }

        public (Guid? TenantId, Guid? JobId) MigrationHandle()
        {
            lock (_lock) return _state == BatchMigrationUserState.Migrating ? (_tenantId, _jobId) : (null, null);
        }

        public void Progress(double percentage, string? operation)
        {
            lock (_lock) { _progress = percentage; _operation = operation; }
        }

        public void Complete(string? note)
        {
            lock (_lock)
            {
                _state = BatchMigrationUserState.Completed;
                _progress = 100;
                _operation = null;
                _error = note;
                _connectionString = null;
            }
        }

        public void Fail(string message)
        {
            lock (_lock)
            {
                _state = BatchMigrationUserState.Failed;
                _error = message;
                _operation = null;
                _connectionString = null;
            }
        }

        public void Cancel()
        {
            lock (_lock)
            {
                if (_state is BatchMigrationUserState.Completed or BatchMigrationUserState.Failed)
                    return;
                _state = BatchMigrationUserState.Cancelled;
                _operation = null;
                _connectionString = null;
            }
        }

        public BatchMigrationUserStatus Snapshot()
        {
            lock (_lock)
            {
                return new BatchMigrationUserStatus
                {
                    Index = index,
                    Slug = Slug,
                    DisplayName = DisplayName,
                    OwnerUsername = OwnerUsername,
                    MongoDatabaseName = DatabaseName,
                    State = _state,
                    ErrorMessage = _error,
                    TenantId = _tenantId,
                    OwnerSubjectId = _subjectId,
                    TenantUrl = tenantUrl,
                    MigrationJobId = _jobId,
                    ProgressPercentage = _progress,
                    CurrentOperation = _operation,
                    SourceEntryCount = _entries,
                    SourceTreatmentCount = _treatments,
                };
            }
        }
    }
}
