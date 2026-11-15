<script lang="ts">
  import { onDestroy } from "svelte";
  import { page } from "$app/state";
  import { replaceState } from "$app/navigation";
  import {
    Card,
    CardContent,
    CardDescription,
    CardHeader,
    CardTitle,
  } from "#lib/components/ui/card/index.js";
  import { Button } from "#lib/components/ui/button/index.js";
  import { Badge } from "#lib/components/ui/badge/index.js";
  import { Input } from "#lib/components/ui/input/index.js";
  import { Label } from "#lib/components/ui/label/index.js";
  import { Textarea } from "#lib/components/ui/textarea/index.js";
  import { Progress } from "#lib/components/ui/progress/index.js";
  import * as Table from "#lib/components/ui/table/index.js";
  import * as Alert from "#lib/components/ui/alert/index.js";
  import Users from "@lucide/svelte/icons/users";
  import Loader2 from "@lucide/svelte/icons/loader-circle";
  import AlertTriangle from "@lucide/svelte/icons/triangle-alert";
  import CheckCircle from "@lucide/svelte/icons/circle-check";
  import Download from "@lucide/svelte/icons/download";
  import Copy from "@lucide/svelte/icons/copy";
  import Link from "@lucide/svelte/icons/link";
  import * as batchRemote from "#lib/api/generated/batchMigrations.generated.remote.js";
  import {
    BatchMigrationUserState,
    type BatchMigrationClaimLink,
    type BatchMigrationStatus,
    type BatchMigrationValidationError,
    type StartBatchMigrationRequest,
  } from "#lib/api/index.js";
  import { fresh } from "#lib/api/fresh-query.js";
  import { remoteErrorMessage } from "#lib/api/remote-error.js";
  import { formatDateTime, formatNumber } from "#lib/utils/formatting.js";
  import {
    BATCH_CSV_TEMPLATE,
    claimLinksCsv,
    parseBatchCsv,
  } from "./batch-csv";

  const MAX_USERS = 100;
  const POLL_MS = 3000;

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------
  let csvText = $state(BATCH_CSV_TEMPLATE);
  let defaultConnectionString = $state("");
  let concurrency = $state(3);

  const parsed = $derived(parseBatchCsv(csvText));
  const tooMany = $derived(parsed.users.length > MAX_USERS);

  let validating = $state(false);
  let starting = $state(false);
  let validationErrors = $state<BatchMigrationValidationError[] | null>(null);
  let validated = $state(false);
  let formError = $state<string | null>(null);

  // Editing the input invalidates an earlier check.
  $effect(() => {
    void csvText;
    void defaultConnectionString;
    void concurrency;
    validated = false;
    validationErrors = null;
  });

  function buildRequest(): StartBatchMigrationRequest {
    return {
      users: parsed.users,
      defaultMongoConnectionString: defaultConnectionString.trim() || undefined,
      collections: [],
      maxConcurrency: concurrency,
    };
  }

  async function loadFile(event: Event) {
    const file = event.currentTarget instanceof HTMLInputElement ? event.currentTarget.files?.[0] : undefined;
    if (file) csvText = await file.text();
  }

  async function validate() {
    validating = true;
    formError = null;
    try {
      const result = await batchRemote.validate(buildRequest());
      validationErrors = result.errors ?? [];
      validated = result.isValid ?? false;
    } catch (err) {
      formError = remoteErrorMessage(err, "Could not check the batch.");
    } finally {
      validating = false;
    }
  }

  async function start() {
    if (!validated) return;
    if (
      !confirm(
        `Create ${parsed.users.length} sites and import each user's Nightscout data? ` +
          "Sites are created as soon as each user's database is reachable.",
      )
    )
      return;

    starting = true;
    formError = null;
    try {
      const status = await batchRemote.start(buildRequest());
      if (status?.id) openBatch(status.id);
    } catch (err) {
      formError = remoteErrorMessage(err, "Could not start the batch.");
    } finally {
      starting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Running / finished batch
  // ---------------------------------------------------------------------------
  const batchesQuery = batchRemote.list();
  const batches = $derived(batchesQuery.current ?? []);

  let activeBatchId = $state<string | null>(page.url.searchParams.get("batch"));
  let activeBatch = $state<BatchMigrationStatus | null>(null);
  let batchError = $state<string | null>(null);
  let pollTimer: ReturnType<typeof setTimeout> | undefined;

  function openBatch(id: string) {
    activeBatchId = id;
    claimLinks = null;
    const url = new URL(page.url.href);
    url.searchParams.set("batch", id);
    // eslint-disable-next-line svelte/no-navigation-without-resolve -- the current page's URL with one param changed, already resolved
    replaceState(url, page.state);
  }

  function closeBatch() {
    clearTimeout(pollTimer);
    activeBatchId = null;
    activeBatch = null;
    const url = new URL(page.url.href);
    url.searchParams.delete("batch");
    // eslint-disable-next-line svelte/no-navigation-without-resolve -- the current page's URL minus one param, already resolved
    replaceState(url, page.state);
  }

  async function poll() {
    clearTimeout(pollTimer);
    const id = activeBatchId;
    if (!id) return;
    try {
      activeBatch = await fresh(batchRemote.getStatus(id));
      batchError = null;
    } catch (err) {
      batchError = remoteErrorMessage(
        err,
        "Could not load this batch. Batches are kept in memory, so an API restart forgets them.",
      );
      activeBatch = null;
      return;
    }
    if (activeBatch?.isRunning) {
      pollTimer = setTimeout(poll, POLL_MS);
    } else {
      void batchesQuery.refresh();
    }
  }

  $effect(() => {
    if (activeBatchId) queueMicrotask(poll);
  });

  onDestroy(() => clearTimeout(pollTimer));

  let cancelling = $state(false);
  async function cancelBatch() {
    if (!activeBatchId || !confirm("Stop this batch? Imports in flight are cancelled; sites already created stay.")) return;
    cancelling = true;
    try {
      await batchRemote.cancel(activeBatchId);
      await poll();
    } catch (err) {
      batchError = remoteErrorMessage(err, "Could not cancel the batch.");
    } finally {
      cancelling = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Claim links
  // ---------------------------------------------------------------------------
  let claimLinks = $state<BatchMigrationClaimLink[] | null>(null);
  let issuingLinks = $state(false);
  let copied = $state<string | null>(null);

  async function issueClaimLinks() {
    if (!activeBatchId) return;
    if (!confirm("Issue a sign-in link for every migrated user? Earlier links stop working once a new one is issued.")) return;
    issuingLinks = true;
    try {
      claimLinks = await batchRemote.claimLinks(activeBatchId);
    } catch (err) {
      batchError = remoteErrorMessage(err, "Could not issue sign-in links.");
    } finally {
      issuingLinks = false;
    }
  }

  async function copy(text: string) {
    await navigator.clipboard.writeText(text);
    copied = text;
    setTimeout(() => (copied = copied === text ? null : copied), 1500);
  }

  function downloadClaimLinks() {
    if (!claimLinks) return;
    const blob = new Blob([claimLinksCsv(claimLinks)], { type: "text/csv" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `nocturne-claim-links-${activeBatchId}.csv`;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  // ---------------------------------------------------------------------------
  // Display helpers
  // ---------------------------------------------------------------------------
  const stateLabel: Record<BatchMigrationUserState, string> = {
    [BatchMigrationUserState.Queued]: "Queued",
    [BatchMigrationUserState.TestingConnection]: "Checking database",
    [BatchMigrationUserState.Provisioning]: "Creating site",
    [BatchMigrationUserState.Migrating]: "Importing",
    [BatchMigrationUserState.Completed]: "Done",
    [BatchMigrationUserState.Failed]: "Failed",
    [BatchMigrationUserState.Cancelled]: "Cancelled",
  };

  function stateVariant(state: BatchMigrationUserState | undefined) {
    switch (state) {
      case BatchMigrationUserState.Completed:
        return "success" as const;
      case BatchMigrationUserState.Failed:
        return "destructive" as const;
      case BatchMigrationUserState.Cancelled:
        return "outline" as const;
      case BatchMigrationUserState.Queued:
        return "secondary" as const;
      default:
        return "info" as const;
    }
  }

  const batchErrors = $derived((validationErrors ?? []).filter((e) => (e.index ?? -1) < 0));
  const rowErrors = $derived((validationErrors ?? []).filter((e) => (e.index ?? -1) >= 0));
</script>

<svelte:head>
  <title>Batch migration · Nocturne</title>
</svelte:head>

<div class="container mx-auto max-w-5xl space-y-6 p-6">
  <div class="flex items-start gap-3">
    <Users class="mt-1 h-6 w-6 text-muted-foreground" />
    <div>
      <h1 class="text-2xl font-semibold">Batch migration</h1>
      <p class="text-muted-foreground">
        Move up to {MAX_USERS} Nightscout users onto this server at once. Each user gets their own
        site at <code>slug.your-domain</code>, filled from their Nightscout MongoDB database. When
        an import finishes, issue each user a sign-in link to claim their site with a passkey.
      </p>
    </div>
  </div>

  {#if !activeBatchId}
    <Card>
      <CardHeader>
        <CardTitle>1. MongoDB connection</CardTitle>
        <CardDescription>
          The connection string used for every user that does not set their own in the list.
          Hosted Nightscout usually keeps every user in one cluster, with a database each.
        </CardDescription>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="space-y-2">
          <Label for="default-connection">Default connection string</Label>
          <Input
            id="default-connection"
            type="password"
            autocomplete="off"
            placeholder="mongodb+srv://user:password@cluster.example.net/?retryWrites=true"
            bind:value={defaultConnectionString}
          />
          <p class="text-xs text-muted-foreground">
            Make sure this server's IP address is allowed to reach the cluster.
          </p>
        </div>
        <div class="space-y-2">
          <Label for="concurrency">Users imported at the same time</Label>
          <Input id="concurrency" type="number" min="1" max="10" class="w-24" bind:value={concurrency} />
        </div>
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle>2. Users</CardTitle>
        <CardDescription>
          One user per line, with a header row. Required columns: <code>slug</code> and
          <code>mongoDatabaseName</code>. Optional: <code>displayName</code>,
          <code>ownerUsername</code> (defaults to the slug), <code>ownerEmail</code>,
          <code>mongoConnectionString</code> (overrides the default). Quote a field that holds a
          comma.
        </CardDescription>
      </CardHeader>
      <CardContent class="space-y-4">
        <Textarea
          rows={12}
          class="font-mono"
          spellcheck={false}
          bind:value={csvText}
          aria-label="Users to migrate, as CSV"
        />
        <div class="flex flex-wrap items-end gap-3">
          <div class="space-y-2">
            <Label for="csv-file">Or load a CSV file</Label>
            <Input id="csv-file" type="file" accept=".csv,text/csv,text/plain" onchange={loadFile} />
          </div>
          <span class="pb-2 text-sm text-muted-foreground">
            {formatNumber(parsed.users.length)} user{parsed.users.length === 1 ? "" : "s"} read
          </span>
        </div>

        {#if parsed.errors.length > 0 || tooMany}
          <Alert.Root variant="destructive">
            <AlertTriangle class="h-4 w-4" />
            <Alert.Title>The list needs fixing</Alert.Title>
            <Alert.Description>
              <ul class="list-disc pl-4">
                {#if tooMany}<li>A batch holds at most {MAX_USERS} users; split the list.</li>{/if}
                {#each parsed.errors as e (e.line + e.message)}
                  <li>{e.line === 0 ? "Header" : `Line ${e.line}`}: {e.message}</li>
                {/each}
              </ul>
            </Alert.Description>
          </Alert.Root>
        {/if}

        {#if parsed.users.length > 0}
          <div class="max-h-80 overflow-auto rounded-md border">
            <Table.Root>
              <Table.Header>
                <Table.Row>
                  <Table.Head>#</Table.Head>
                  <Table.Head>Subdomain</Table.Head>
                  <Table.Head>Name</Table.Head>
                  <Table.Head>Username</Table.Head>
                  <Table.Head>Database</Table.Head>
                  <Table.Head>Connection</Table.Head>
                  <Table.Head>Check</Table.Head>
                </Table.Row>
              </Table.Header>
              <Table.Body>
                {#each parsed.users as user, i (i)}
                  {@const problems = rowErrors.filter((e) => e.index === i)}
                  <Table.Row class="align-top">
                    <Table.Cell class="tabular-nums">{i + 1}</Table.Cell>
                    <Table.Cell class="font-mono">{user.slug}</Table.Cell>
                    <Table.Cell>{user.displayName}</Table.Cell>
                    <Table.Cell class="font-mono">{user.ownerUsername ?? user.slug}</Table.Cell>
                    <Table.Cell class="font-mono">{user.mongoDatabaseName}</Table.Cell>
                    <Table.Cell >{user.mongoConnectionString ? "Own" : "Default"}</Table.Cell>
                    <Table.Cell >
                      {#if problems.length > 0}
                        <span class="text-destructive">{problems.map((p) => p.message).join(" ")}</span>
                      {:else if validated}
                        <CheckCircle class="h-4 w-4 text-success" />
                      {/if}
                    </Table.Cell>
                  </Table.Row>
                {/each}
              </Table.Body>
            </Table.Root>
          </div>
        {/if}
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle>3. Check and start</CardTitle>
        <CardDescription>
          Checking makes sure every subdomain is free and every row is complete; it creates
          nothing. Each user's database is tested when their turn comes, before their site is
          created.
        </CardDescription>
      </CardHeader>
      <CardContent class="space-y-4">
        {#if formError}
          <Alert.Root variant="destructive">
            <AlertTriangle class="h-4 w-4" />
            <Alert.Description>{formError}</Alert.Description>
          </Alert.Root>
        {/if}
        {#if batchErrors.length > 0}
          <Alert.Root variant="destructive">
            <AlertTriangle class="h-4 w-4" />
            <Alert.Description>{batchErrors.map((e) => e.message).join(" ")}</Alert.Description>
          </Alert.Root>
        {/if}
        {#if validationErrors && !validated && rowErrors.length > 0}
          <p class="text-sm text-destructive">
            {rowErrors.length} problem{rowErrors.length === 1 ? "" : "s"} found; see the Check column above.
          </p>
        {/if}
        {#if validated}
          <p class="flex items-center gap-2 text-sm text-success">
            <CheckCircle class="h-4 w-4" /> Every row is ready.
          </p>
        {/if}
        <div class="flex gap-3">
          <Button
            variant="outline"
            onclick={validate}
            disabled={validating || parsed.users.length === 0 || tooMany || parsed.errors.length > 0}
          >
            {#if validating}<Loader2 class="mr-2 h-4 w-4 animate-spin" />{/if}
            Check
          </Button>
          <Button onclick={start} disabled={!validated || starting}>
            {#if starting}<Loader2 class="mr-2 h-4 w-4 animate-spin" />{/if}
            Start migration of {formatNumber(parsed.users.length)} users
          </Button>
        </div>
      </CardContent>
    </Card>

    {#if batches.length > 0}
      <Card>
        <CardHeader>
          <CardTitle>Recent batches</CardTitle>
          <CardDescription>Kept until the API restarts.</CardDescription>
        </CardHeader>
        <CardContent>
          <Table.Root>
            <Table.Header>
              <Table.Row>
                <Table.Head>Started</Table.Head>
                <Table.Head>Users</Table.Head>
                <Table.Head>Done</Table.Head>
                <Table.Head>Failed</Table.Head>
                <Table.Head></Table.Head>
              </Table.Row>
            </Table.Header>
            <Table.Body>
              {#each batches as b (b.id)}
                <Table.Row>
                  <Table.Cell>{b.createdAt ? formatDateTime(b.createdAt) : ""}</Table.Cell>
                  <Table.Cell class="tabular-nums">{b.total}</Table.Cell>
                  <Table.Cell class="tabular-nums">{b.completedCount}</Table.Cell>
                  <Table.Cell class="tabular-nums">{b.failedCount}</Table.Cell>
                  <Table.Cell class="text-right">
                    {#if b.isRunning}<Badge variant="info">Running</Badge>{/if}
                    <Button variant="ghost" size="sm" onclick={() => b.id && openBatch(b.id)}>Open</Button>
                  </Table.Cell>
                </Table.Row>
              {/each}
            </Table.Body>
          </Table.Root>
        </CardContent>
      </Card>
    {/if}
  {:else}
    <div>
      <Button
        variant="ghost"
        size="sm"
        onclick={closeBatch}
      >
        ← New batch
      </Button>
    </div>

    {#if batchError}
      <Alert.Root variant="destructive">
        <AlertTriangle class="h-4 w-4" />
        <Alert.Description>{batchError}</Alert.Description>
      </Alert.Root>
    {/if}

    {#if activeBatch}
      {@const b = activeBatch}
      <Card>
        <CardHeader>
          <CardTitle class="flex items-center gap-2">
            {#if b.isRunning}
              <Loader2 class="h-5 w-5 animate-spin" /> Migrating
            {:else}
              Finished
            {/if}
          </CardTitle>
          <CardDescription>
            {b.completedCount} of {b.total} done, {b.failedCount} failed · {b.maxConcurrency} at a time
            {#if b.createdAt}· started {formatDateTime(b.createdAt)}{/if}
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-4">
          <Progress
            value={b.total ? (((b.completedCount ?? 0) + (b.failedCount ?? 0)) / b.total) * 100 : 0}
            max={100}
            aria-label="Batch progress"
          />
          <div class="flex flex-wrap gap-3">
            {#if b.isRunning}
              <Button variant="destructive" onclick={cancelBatch} disabled={cancelling}>
                {#if cancelling}<Loader2 class="mr-2 h-4 w-4 animate-spin" />{/if}
                Stop batch
              </Button>
            {/if}
            <Button onclick={issueClaimLinks} disabled={issuingLinks || (b.completedCount ?? 0) === 0}>
              {#if issuingLinks}<Loader2 class="mr-2 h-4 w-4 animate-spin" />{:else}<Link class="mr-2 h-4 w-4" />{/if}
              Issue sign-in links
            </Button>
          </div>

          <div class="overflow-auto rounded-md border">
            <Table.Root>
              <Table.Header>
                <Table.Row>
                  <Table.Head>#</Table.Head>
                  <Table.Head>Site</Table.Head>
                  <Table.Head>Database</Table.Head>
                  <Table.Head>Source records</Table.Head>
                  <Table.Head>Status</Table.Head>
                  <Table.Head class="w-48">Progress</Table.Head>
                </Table.Row>
              </Table.Header>
              <Table.Body>
                {#each b.users ?? [] as u (u.index)}
                  <Table.Row class="align-top">
                    <Table.Cell class="tabular-nums">{(u.index ?? 0) + 1}</Table.Cell>
                    <Table.Cell>
                      <div>{u.displayName}</div>
                      {#if u.tenantUrl && u.tenantId}
                        <!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- another tenant's absolute origin, not a route of this app -->
                        <a class="font-mono text-xs underline" href={u.tenantUrl} target="_blank" rel="noreferrer">{u.slug}</a>
                      {:else}
                        <span class="font-mono text-xs">{u.slug}</span>
                      {/if}
                    </Table.Cell>
                    <Table.Cell class="font-mono">{u.mongoDatabaseName}</Table.Cell>
                    <Table.Cell class="tabular-nums">
                      {#if u.sourceEntryCount != null}
                        {formatNumber(u.sourceEntryCount)} entries<br />
                        {formatNumber(u.sourceTreatmentCount ?? 0)} treatments
                      {/if}
                    </Table.Cell>
                    <Table.Cell>
                      <Badge variant={stateVariant(u.state)}>{u.state != null ? stateLabel[u.state] : ""}</Badge>
                      {#if u.errorMessage}
                        <p class="mt-1 max-w-xs text-xs {u.state === BatchMigrationUserState.Failed ? 'text-destructive' : 'text-muted-foreground'}">
                          {u.errorMessage}
                        </p>
                      {/if}
                    </Table.Cell>
                    <Table.Cell>
                      {#if u.state === BatchMigrationUserState.Migrating || u.state === BatchMigrationUserState.Completed}
                        <Progress value={u.progressPercentage ?? 0} max={100} aria-label="Import progress for {u.slug}" />
                      {/if}
                      {#if u.currentOperation}
                        <p class="mt-1 text-xs text-muted-foreground">{u.currentOperation}</p>
                      {/if}
                    </Table.Cell>
                  </Table.Row>
                {/each}
              </Table.Body>
            </Table.Root>
          </div>
        </CardContent>
      </Card>

      {#if claimLinks}
        <Card>
          <CardHeader>
            <CardTitle>Sign-in links</CardTitle>
            <CardDescription>
              Send each user their link. It works once, expires after 24 hours, and lets them add
              a passkey to take over their site. Issue new links here if one expires. These links
              grant access to health data: send them privately.
            </CardDescription>
          </CardHeader>
          <CardContent class="space-y-4">
            <Button variant="outline" onclick={downloadClaimLinks}>
              <Download class="mr-2 h-4 w-4" /> Download as CSV
            </Button>
            <div class="overflow-auto rounded-md border">
              <Table.Root>
                <Table.Header>
                  <Table.Row>
                    <Table.Head>Site</Table.Head>
                    <Table.Head>Username</Table.Head>
                    <Table.Head>Link</Table.Head>
                    <Table.Head>Expires</Table.Head>
                  </Table.Row>
                </Table.Header>
                <Table.Body>
                  {#each claimLinks as l (l.index)}
                    <Table.Row>
                      <Table.Cell class="font-mono">{l.slug}</Table.Cell>
                      <Table.Cell class="font-mono">{l.ownerUsername}</Table.Cell>
                      <Table.Cell >
                        {#if l.url}
                          <Button variant="ghost" size="sm" onclick={() => l.url && copy(l.url)}>
                            <Copy class="mr-1 h-3 w-3" />
                            {copied === l.url ? "Copied" : "Copy link"}
                          </Button>
                        {:else if l.code}
                          <code>{l.code}</code>
                          <span class="text-muted-foreground">(no BASE_DOMAIN set)</span>
                        {:else}
                          <span class="text-muted-foreground">{l.errorMessage}</span>
                        {/if}
                      </Table.Cell>
                      <Table.Cell >{l.expiresAt ? formatDateTime(l.expiresAt) : ""}</Table.Cell>
                    </Table.Row>
                  {/each}
                </Table.Body>
              </Table.Root>
            </div>
          </CardContent>
        </Card>
      {/if}
    {:else if !batchError}
      <p class="flex items-center gap-2 text-muted-foreground">
        <Loader2 class="h-4 w-4 animate-spin" /> Loading batch…
      </p>
    {/if}
  {/if}
</div>
