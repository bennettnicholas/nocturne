using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using OpenApi.Remote.Attributes;
using Nocturne.API.Extensions;
using Nocturne.API.Services.Auth;
using Nocturne.API.Services.Migration;
using Nocturne.Core.Contracts.Auth;
using Nocturne.Core.Contracts.Multitenancy;
using Nocturne.Infrastructure.Data.Entities;
using Nocturne.Infrastructure.Data.Services;

namespace Nocturne.API.Controllers.V4.PlatformAdmin;

/// <summary>
/// Platform-admin controller for moving many Nightscout users onto this instance at once.
/// </summary>
/// <remarks>
/// Each user in a batch becomes a new tenant with an owner who holds no credential yet, filled from
/// that user's Nightscout MongoDB database by the ordinary migration job. Once a user's import is
/// done, <see cref="ClaimLinks"/> issues the single-use link they open to enrol a passkey and take
/// over their site. Restricted to the <c>platform_admin</c> role, which an instance-key caller also
/// holds, so a batch can be run from a script as well as from the admin page.
/// </remarks>
/// <seealso cref="IBatchMigrationService"/>
[ApiController]
[Tags("PlatformAdmin")]
[Route("api/v4/admin/batch-migrations")]
[Produces("application/json")]
[Authorize(Roles = "platform_admin")]
public class BatchMigrationController : ControllerBase
{
    private readonly IBatchMigrationService _batches;
    private readonly ITenantService _tenants;

    public BatchMigrationController(IBatchMigrationService batches, ITenantService tenants)
    {
        _batches = batches;
        _tenants = tenants;
    }

    /// <summary>Checks a batch's rows without creating anything.</summary>
    [HttpPost("validate")]
    [RemoteCommand]
    [ProducesResponseType(typeof(BatchMigrationValidationResult), StatusCodes.Status200OK)]
    public async Task<IActionResult> Validate(
        [FromBody] StartBatchMigrationRequest request, CancellationToken ct) =>
        Ok(await _batches.ValidateAsync(request, _tenants, ct));

    /// <summary>
    /// Starts a batch: every row is tested, provisioned and imported in the background, a few at a
    /// time. Returns 400 with the validation errors when any row is refused, and starts nothing.
    /// </summary>
    [HttpPost]
    [RemoteCommand(Invalidates = ["List"])]
    [ProducesResponseType(typeof(BatchMigrationStatus), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(BatchMigrationValidationResult), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> Start(
        [FromBody] StartBatchMigrationRequest request, CancellationToken ct)
    {
        var validation = await _batches.ValidateAsync(request, _tenants, ct);
        if (!validation.IsValid)
            return BadRequest(validation);

        var status = await _batches.StartAsync(request, _tenants, ct);
        return AcceptedAtAction(nameof(GetStatus), new { id = status.Id }, status);
    }

    /// <summary>The batches this API process has run since it started, newest first.</summary>
    [HttpGet]
    [RemoteQuery]
    [ProducesResponseType(typeof(List<BatchMigrationSummary>), StatusCodes.Status200OK)]
    public IActionResult List() => Ok(_batches.List());

    /// <summary>A batch and every user in it.</summary>
    [HttpGet("{id:guid}")]
    [RemoteQuery]
    [ProducesResponseType(typeof(BatchMigrationStatus), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public IActionResult GetStatus(Guid id) =>
        _batches.GetStatus(id) is { } status ? Ok(status) : NotFound();

    /// <summary>Stops queued users from starting and cancels the imports in flight.</summary>
    [HttpPost("{id:guid}/cancel")]
    [RemoteCommand(Invalidates = ["List", "GetStatus"])]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Cancel(Guid id) =>
        await _batches.CancelAsync(id) ? NoContent() : NotFound();

    /// <summary>
    /// Issues a single-use recovery link for the owner of every site the batch created and
    /// imported, which they open to enrol a passkey. A link expires after 24 hours and calling this
    /// again issues fresh ones; an owner who has already enrolled a sign-in method gets none.
    /// </summary>
    [HttpPost("{id:guid}/claim-links")]
    [RemoteCommand]
    [ResponseCache(NoStore = true, Location = ResponseCacheLocation.None)]
    [ProducesResponseType(typeof(List<BatchMigrationClaimLink>), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> ClaimLinks(
        Guid id,
        [FromServices] INocturneDbContextFactory dbContextFactory,
        [FromServices] ILoginCodeService loginCodeService,
        [FromServices] MemberRecoveryEligibility eligibility,
        CancellationToken ct)
    {
        if (_batches.GetStatus(id) is not { } batch)
            return NotFound();

        var actor = AuthAuditActor.From(HttpContext.GetAuthContext());
        var ip = HttpContext.Connection.RemoteIpAddress?.ToString();
        var userAgent = Request.Headers.UserAgent.ToString();
        var links = new List<BatchMigrationClaimLink>();

        foreach (var user in batch.Users.Where(u => u.State == BatchMigrationUserState.Completed))
        {
            if (user.TenantId is not { } tenantId || user.OwnerSubjectId is not { } subjectId)
                continue;

            await using var db = await dbContextFactory.CreateForTenantAsync(tenantId, ct);

            if (await eligibility.CheckAsync(db, tenantId, subjectId, ct) == RecoveryEligibility.NotLockedOut)
            {
                links.Add(new(user.Index, user.Slug, user.OwnerUsername, user.TenantUrl, null, null,
                    "The owner can already sign in."));
                continue;
            }

            var code = await loginCodeService.IssueAsync(
                db, subjectId, LoginCodePurpose.OperatorRecovery, ip, userAgent, actor, ct);

            var url = user.TenantUrl is { } origin
                ? $"{origin}/auth/recovery?code={Uri.EscapeDataString(code.Code)}"
                : null;

            links.Add(new(user.Index, user.Slug, user.OwnerUsername, url, code.Code, code.ExpiresAt, null));
        }

        return Ok(links);
    }
}
