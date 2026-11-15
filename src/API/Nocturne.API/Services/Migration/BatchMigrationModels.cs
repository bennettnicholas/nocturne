namespace Nocturne.API.Services.Migration;

/// <summary>
/// A platform administrator's request to move many Nightscout users onto this instance at once:
/// one new tenant per row, each filled from that user's Nightscout MongoDB database.
/// </summary>
public record StartBatchMigrationRequest
{
    /// <summary>The users to migrate, at most <see cref="BatchMigrationLimits.MaxUsers"/>.</summary>
    public List<BatchMigrationUserRequest> Users { get; init; } = [];

    /// <summary>
    /// The MongoDB connection string a row without its own uses. Hosted Nightscout providers
    /// usually keep every user in one cluster with a database each, so one string and a database
    /// name per row is the common shape.
    /// </summary>
    public string? DefaultMongoConnectionString { get; init; }

    /// <summary>Collections to import for every user. Empty imports all of them.</summary>
    public List<string> Collections { get; init; } = [];

    /// <summary>Optional lower bound of the import window, for every user.</summary>
    public DateTime? StartDate { get; init; }

    /// <summary>Optional upper bound of the import window, for every user.</summary>
    public DateTime? EndDate { get; init; }

    /// <summary>
    /// How many users are tested, provisioned and imported at the same time, from 1 to
    /// <see cref="BatchMigrationLimits.MaxConcurrency"/>. Defaults to
    /// <see cref="BatchMigrationLimits.DefaultConcurrency"/>.
    /// </summary>
    public int? MaxConcurrency { get; init; }
}

/// <summary>One user in a <see cref="StartBatchMigrationRequest"/>.</summary>
public record BatchMigrationUserRequest
{
    /// <summary>The new tenant's subdomain: the site is served at <c>{slug}.{BASE_DOMAIN}</c>.</summary>
    public string Slug { get; init; } = string.Empty;

    /// <summary>The new tenant's display name, and the owner's name.</summary>
    public string DisplayName { get; init; } = string.Empty;

    /// <summary>The owner's username. Defaults to the slug.</summary>
    public string? OwnerUsername { get; init; }

    /// <summary>The owner's email, kept on the owner account.</summary>
    public string? OwnerEmail { get; init; }

    /// <summary>This user's MongoDB connection string, when it differs from the batch default.</summary>
    public string? MongoConnectionString { get; init; }

    /// <summary>This user's Nightscout MongoDB database.</summary>
    public string MongoDatabaseName { get; init; } = string.Empty;
}

/// <summary>Bounds on a batch migration.</summary>
public static class BatchMigrationLimits
{
    public const int MaxUsers = 100;
    public const int MaxConcurrency = 10;
    public const int DefaultConcurrency = 3;
}

/// <summary>Where one user of a batch has got to.</summary>
public enum BatchMigrationUserState
{
    /// <summary>Waiting for a free slot.</summary>
    Queued = 0,

    /// <summary>Checking that the MongoDB database can be read.</summary>
    TestingConnection = 1,

    /// <summary>Creating the tenant and its owner.</summary>
    Provisioning = 2,

    /// <summary>The migration job is importing the user's data.</summary>
    Migrating = 3,

    /// <summary>The tenant exists and its import completed.</summary>
    Completed = 4,

    /// <summary>A step failed; <see cref="BatchMigrationUserStatus.ErrorMessage"/> says which.</summary>
    Failed = 5,

    /// <summary>The batch was cancelled before this user finished.</summary>
    Cancelled = 6,
}

/// <summary>A batch and every user in it. Never carries a connection string.</summary>
public record BatchMigrationStatus
{
    public required Guid Id { get; init; }
    public required DateTime CreatedAt { get; init; }
    public DateTime? CompletedAt { get; init; }

    /// <summary>Whether any user is still queued or in flight.</summary>
    public required bool IsRunning { get; init; }

    public required int MaxConcurrency { get; init; }
    public required int Total { get; init; }
    public required int CompletedCount { get; init; }
    public required int FailedCount { get; init; }
    public required List<BatchMigrationUserStatus> Users { get; init; }
}

/// <summary>One user's progress in a <see cref="BatchMigrationStatus"/>.</summary>
public record BatchMigrationUserStatus
{
    public required int Index { get; init; }
    public required string Slug { get; init; }
    public required string DisplayName { get; init; }
    public required string OwnerUsername { get; init; }
    public required string MongoDatabaseName { get; init; }
    public required BatchMigrationUserState State { get; init; }
    public string? ErrorMessage { get; init; }

    /// <summary>The tenant made for the user, once provisioning succeeded.</summary>
    public Guid? TenantId { get; init; }

    /// <summary>The owner account made for the user, once provisioning succeeded.</summary>
    public Guid? OwnerSubjectId { get; init; }

    /// <summary>The site's address, when the instance has a base domain.</summary>
    public string? TenantUrl { get; init; }

    /// <summary>The migration job importing the user's data, once started.</summary>
    public Guid? MigrationJobId { get; init; }

    public double ProgressPercentage { get; init; }
    public string? CurrentOperation { get; init; }
    public long? SourceEntryCount { get; init; }
    public long? SourceTreatmentCount { get; init; }
}

/// <summary>A summary row for the list of batches.</summary>
public record BatchMigrationSummary(
    Guid Id,
    DateTime CreatedAt,
    DateTime? CompletedAt,
    bool IsRunning,
    int Total,
    int CompletedCount,
    int FailedCount);

/// <summary>A problem with one row of a batch, found before anything was created.</summary>
public record BatchMigrationValidationError(int Index, string? Slug, string Message);

/// <summary>The outcome of checking a batch without starting it.</summary>
public record BatchMigrationValidationResult
{
    public required bool IsValid { get; init; }
    public required List<BatchMigrationValidationError> Errors { get; init; }
}

/// <summary>A sign-in link for one migrated user to claim their site with a passkey.</summary>
public record BatchMigrationClaimLink(
    int Index,
    string Slug,
    string OwnerUsername,
    string? Url,
    string? Code,
    DateTime? ExpiresAt,
    string? ErrorMessage);
