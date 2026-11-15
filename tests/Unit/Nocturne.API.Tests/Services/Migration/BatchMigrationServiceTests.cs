using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Moq;
using Nocturne.API.Multitenancy;
using Nocturne.API.Services.Migration;
using Nocturne.Core.Contracts.Multitenancy;
using Xunit;

namespace Nocturne.API.Tests.Services.Migration;

[Trait("Category", "Unit")]
public class BatchMigrationServiceTests
{
    private readonly Mock<IMigrationJobService> _migrations = new();
    private readonly Mock<ITenantService> _tenants = new();
    private readonly Mock<IServiceScopeFactory> _scopes = new(MockBehavior.Strict);

    public BatchMigrationServiceTests()
    {
        _tenants
            .Setup(t => t.ValidateSlugAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new SlugValidationResult(true));
    }

    private BatchMigrationService Service() => new(
        _scopes.Object,
        _migrations.Object,
        Options.Create(new BaseDomainOptions { BaseDomain = "nocturne.example" }),
        TimeProvider.System,
        NullLogger<BatchMigrationService>.Instance);

    private static BatchMigrationUserRequest User(string slug, string db = "ns_db") =>
        new() { Slug = slug, DisplayName = slug, MongoDatabaseName = db };

    [Fact]
    public async Task AcceptsRowsThatUseTheDefaultConnectionString()
    {
        var result = await Service().ValidateAsync(new StartBatchMigrationRequest
        {
            DefaultMongoConnectionString = "mongodb://cluster",
            Users = [User("jane"), User("bob")],
        }, _tenants.Object);

        result.IsValid.Should().BeTrue();
        result.Errors.Should().BeEmpty();
    }

    [Fact]
    public async Task RefusesAnEmptyBatch()
    {
        var result = await Service().ValidateAsync(new StartBatchMigrationRequest(), _tenants.Object);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().ContainSingle(e => e.Index == -1);
    }

    [Fact]
    public async Task RefusesMoreThanTheLimit()
    {
        var users = Enumerable.Range(0, BatchMigrationLimits.MaxUsers + 1).Select(i => User($"u{i}")).ToList();

        var result = await Service().ValidateAsync(new StartBatchMigrationRequest
        {
            DefaultMongoConnectionString = "mongodb://cluster",
            Users = users,
        }, _tenants.Object);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.Index == -1 && e.Message.Contains("100"));
    }

    [Fact]
    public async Task FlagsADuplicateSlugOnTheSecondRow()
    {
        var result = await Service().ValidateAsync(new StartBatchMigrationRequest
        {
            DefaultMongoConnectionString = "mongodb://cluster",
            Users = [User("jane"), User("JANE")],
        }, _tenants.Object);

        result.Errors.Should().ContainSingle().Which.Index.Should().Be(1);
    }

    [Fact]
    public async Task FlagsATakenSlugAndAMissingConnectionAndDatabase()
    {
        _tenants
            .Setup(t => t.ValidateSlugAsync("taken", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new SlugValidationResult(false, "This subdomain is already taken"));

        var result = await Service().ValidateAsync(new StartBatchMigrationRequest
        {
            Users = [User("taken"), User("jane", db: "")],
        }, _tenants.Object);

        result.Errors.Where(e => e.Index == 0).Select(e => e.Message)
            .Should().Contain("This subdomain is already taken");
        result.Errors.Where(e => e.Index == 1).Should().HaveCount(2, "the row has neither a database nor a connection string");
    }

    [Fact]
    public async Task AnUnreadableDatabaseFailsTheRowBeforeAnythingIsCreated()
    {
        _migrations
            .Setup(m => m.TestConnectionAsync(It.IsAny<TestMigrationConnectionRequest>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TestMigrationConnectionResult { IsSuccess = false, ErrorMessage = "auth failed" });

        var service = Service();
        var started = await service.StartAsync(new StartBatchMigrationRequest
        {
            DefaultMongoConnectionString = "mongodb://cluster",
            Users = [User("jane")],
        }, _tenants.Object);

        started.Users.Should().ContainSingle().Which.TenantUrl.Should().Be("https://jane.nocturne.example");

        var status = await WaitUntilFinishedAsync(service, started.Id);

        var row = status.Users.Should().ContainSingle().Subject;
        row.State.Should().Be(BatchMigrationUserState.Failed);
        row.ErrorMessage.Should().Contain("auth failed");
        row.TenantId.Should().BeNull();
        status.FailedCount.Should().Be(1);

        // The strict scope factory throws if provisioning had been attempted.
        _scopes.VerifyNoOtherCalls();
        _migrations.Verify(
            m => m.StartMigrationAsync(It.IsAny<StartMigrationRequest>(), It.IsAny<TenantContext?>(), It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task StartRefusesAnInvalidBatch()
    {
        var act = () => Service().StartAsync(new StartBatchMigrationRequest(), _tenants.Object);
        await act.Should().ThrowAsync<ArgumentException>();
    }

    private static async Task<BatchMigrationStatus> WaitUntilFinishedAsync(IBatchMigrationService service, Guid id)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            var status = service.GetStatus(id)!;
            if (!status.IsRunning)
                return status;
            await Task.Delay(20);
        }

        throw new TimeoutException("The batch did not finish.");
    }
}
