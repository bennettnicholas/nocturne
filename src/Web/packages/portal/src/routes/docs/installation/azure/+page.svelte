<script lang="ts">
    import { ArtworkHero } from "water-ui";
    import { DOCS_HERO } from "#lib/data/docs-artwork.js";
    import Callout from "@nocturne/cms/components/Callout.svelte";
    import NextSteps from "#lib/components/docs/NextSteps.svelte";
    import SupportNocturne from "#lib/components/docs/SupportNocturne.svelte";
    import CodeBlock from "#lib/components/docs/CodeBlock.svelte";
    import InstallGuideBar from "#lib/components/docs/install/InstallGuideBar.svelte";
    import StepHeading from "#lib/components/docs/install/StepHeading.svelte";
    import RouteChoice from "#lib/components/docs/install/RouteChoice.svelte";
    import Domain from "#lib/components/docs/install/Domain.svelte";
    import SiteLink from "#lib/components/docs/install/SiteLink.svelte";
    import DuckDnsSteps from "#lib/components/docs/install/DuckDnsSteps.svelte";
    import { resolve } from "$app/paths";
    import { createInstallGuide } from "#lib/components/docs/install/guide.svelte.js";

    const guide = createInstallGuide({ id: "azure" });
    const mac = $derived(guide.choice("computer", "windows") === "mac");
    // The deploy script sets the DNS record of a name under duckdns.org itself, given the token.
    const duckDns = $derived(guide.host?.toLowerCase().endsWith(".duckdns.org") ?? false);

    // Where the one-line installers are published: deploy/azure-cloud in the repository.
    // @wc-ignore
    const TOOLKIT = "https://raw.githubusercontent.com/nightscout/nocturne/main/deploy/azure-cloud";
    // @wc-ignore
    const FALLBACK_DOMAIN = "nocturne.example.com";

    const domainName = $derived(guide.host ?? FALLBACK_DOMAIN);
    // @wc-ignore
    const dnsRecords = $derived(`${domainName}      A   <the IP address>\n*.${domainName}    A   <the IP address>`);

    // Without a domain, the plain form (the script asks for one). With one, the form that passes it.
    const runCommand = $derived.by(() => {
        if (mac) {
            const get = `curl -fsSL ${TOOLKIT}/get-nocturne.sh | bash`;
            return guide.host ? `${get} -s -- --domain ${guide.host}` : get;
        }
        const url = `${TOOLKIT}/get-nocturne.ps1`;
        return guide.host
            ? `& ([scriptblock]::Create((irm ${url}))) -Domain ${guide.host}`
            : `irm ${url} | iex`;
    });
    // The one-line command with an action, such as Remove. It downloads the toolkit from GitHub
    // again, so it works on any computer, from any folder.
    // @wc-ignore
    const actionPrefix = $derived(
        mac ? `curl -fsSL ${TOOLKIT}/get-nocturne.sh | bash -s --` : `& ([scriptblock]::Create((irm ${TOOLKIT}/get-nocturne.ps1)))`,
    );
    const actionCommand = (action: string) =>
        `${actionPrefix} ${mac ? `--action ${action.toLowerCase()}` : `-Action ${action}`}`;

    const ACTIONS = [
        { action: "Info", what: "Show the address, IP address and SSH details" },
        { action: "Logs", what: "Show container status and recent logs" },
        { action: "Ssh", what: "Open a shell on the server. Everything lives in /opt/nocturne" },
        { action: "Reinstall", what: "Run the install script on the server again, keeping your data and passwords" },
        { action: "Remove", what: "Delete everything in Azure and stop billing. You type the name to confirm" },
    ];

    const STEPS = [
        { id: "step-1", title: "Open a terminal" },
        { id: "step-2", title: "Run the deploy" },
        { id: "step-3", title: "Region, size and DNS" },
        { id: "step-4", title: "Create your first site" },
    ];

    const COMPUTERS = [
        {
            value: "windows",
            title: "Windows",
            description: "Windows 10 or 11. The script runs in PowerShell and installs the Azure CLI with winget.",
        },
        {
            value: "mac",
            title: "Mac",
            description: "Apple silicon or Intel. The script runs in Terminal and installs the Azure CLI with Homebrew.",
        },
    ];

    const hero = DOCS_HERO["installation/azure"];
</script>

<div class="max-w-3xl">
    <ArtworkHero
        artwork={hero.artwork}
        palette={hero.palette}
        motion="auto"
        autoplay="once"
        size={400}
        wrap={hero.wrap ?? true}
    />
    <h1 class="text-4xl font-bold tracking-tight mb-4">Microsoft Azure</h1>
    <p class="text-lg text-muted-foreground mb-8">
        Run Nocturne on a small Linux server in your own Azure subscription. One command on your
        Windows PC or Mac creates the server, the network, HTTPS and Nocturne itself. No SSH or
        Docker knowledge needed. Most people pay about $20–35 a month.
    </p>
    <p class="text-muted-foreground mb-8">
        On the server, it runs the same
        <a href={resolve("/docs/installation/install-script")} class="text-primary hover:underline">install script</a>
        as any other Linux server. If you have a server, use that guide.
    </p>

    <h2 class="text-2xl font-bold mt-8 mb-4">What you need</h2>
    <ul class="list-disc list-inside space-y-2 text-muted-foreground mb-8">
        <li>
            An <a href="https://azure.microsoft.com/free" class="text-primary hover:underline">Azure account</a>
            with a subscription. Azure is billed by the hour, so the server costs money for as long
            as it exists. The script shows an estimate before it creates anything.
        </li>
        <li>A Windows 10/11 PC or a Mac, and about 15–30 minutes.</li>
        <li>
            A domain name. Nocturne gives every site its own subdomain, so the DNS provider must
            support wildcard records. If you do not have a domain, a free one from DuckDNS works well.
        </li>
    </ul>

    <InstallGuideBar steps={STEPS} placeholder="yourname.duckdns.org" />

    {#if !guide.host || duckDns}
    <h2 id="duckdns" class="text-2xl font-bold mt-8 mb-4 scroll-mt-36">
        {#if duckDns}Your DuckDNS token{:else}No domain yet? Get one from DuckDNS{/if}
    </h2>
    <DuckDnsSteps />
    <p class="text-muted-foreground mb-8">
        {#if duckDns}
            The deploy script asks for the token in
            <a href="#step-2" class="text-primary hover:underline">Step 2</a>.
        {:else}
            Then enter your domain in the bar at the top of the page. If you already own a
            domain, enter that domain instead and ignore this section.
        {/if}
    </p>
    {/if}

    <h2 class="text-2xl font-bold mt-8 mb-4">Your computer</h2>
    <p class="text-muted-foreground mb-4">
        Select the computer you will run the script on. The command in
        <a href="#step-2" class="text-primary hover:underline">Step 2</a> matches it. Either one
        creates the same server, so you can manage it later from the other.
    </p>
    <RouteChoice id="computer" label="Which computer you are using" options={COMPUTERS} fallback="windows" />

    <StepHeading id="step-1" installStep="1">Step 1: Open a terminal</StepHeading>
    {#if mac}
        <p class="text-muted-foreground mb-8">
            Open <strong>Terminal</strong>, from Applications, then Utilities, or by searching for it
            with Spotlight. The script installs Homebrew if you do not have it, asking first, then the
            Azure CLI, jq and Bicep.
        </p>
    {:else}
        <p class="text-muted-foreground mb-8">
            Open <strong>PowerShell</strong>: select Start and type "PowerShell". It does not need to run as
            administrator. The script installs the Azure CLI and Bicep if they are missing.
        </p>
    {/if}

    <StepHeading id="step-2" installStep="2">Step 2: Run the deploy</StepHeading>
    {#if guide.host}
        <p class="text-muted-foreground mb-4">
            Paste this into {mac ? "Terminal" : "PowerShell"}. The command contains your domain.
            Nocturne will answer on <Domain fallback={FALLBACK_DOMAIN} />. Every site you create gets
            a subdomain under it, so pick something you are happy to keep.
        </p>
    {:else}
        <p class="text-muted-foreground mb-4">
            Paste this into {mac ? "Terminal" : "PowerShell"}. The script asks for your domain. Or enter
            it in the bar at the top of the page first, and the command contains it.
        </p>
    {/if}
    <CodeBlock code={runCommand} class="mb-4" />
    <p class="text-muted-foreground mb-4">
        The command downloads the toolkit to a <code class="text-xs bg-muted/50 px-1.5 py-0.5 rounded">nocturne-azure</code>
        folder in your home folder and starts the deploy. A browser window opens for the Azure
        sign-in, including MFA.
    </p>
    <Callout type="tip" title="Several directories, or the sign-in will not open">
        <p class="mb-2">
            If your account belongs to more than one Azure directory, or your organization requires
            MFA, add your tenant ID. If no browser can open, sign in with a code instead:
        </p>
        <CodeBlock
            code={mac
                ? `curl -fsSL ${TOOLKIT}/get-nocturne.sh | bash -s -- --tenant-id <your-tenant-id> --device-code`
                : `& ([scriptblock]::Create((irm ${TOOLKIT}/get-nocturne.ps1))) -TenantId <your-tenant-id> -DeviceCode`}
        />
    </Callout>
    <details class="mb-4">
        <summary class="text-sm font-medium text-muted-foreground cursor-pointer hover:text-foreground">What the script does</summary>
        <ul class="list-disc list-inside space-y-1 text-sm text-muted-foreground mt-2 mb-2">
            <li>Installs the tools it needs and creates an SSH key for the server</li>
            <li>Signs you in to Azure and asks which region and server size to use</li>
            <li>Shows the estimated monthly cost from Azure's live price list, and creates nothing until you confirm</li>
            <li>Creates the server, its network, a firewall and a static IP address, all in one resource group named <strong>rg-nocturne</strong></li>
            <li>Opens only ports 80 and 443 to the internet, and SSH only to your current IP address. Password login is off</li>
            <li>Uses Trusted Launch (secure boot and vTPM) where the size supports it</li>
            <li>Points your DuckDNS name at the server when you give it the token, or prints the two DNS records to create</li>
            <li>On first boot, the server runs the same install script as the install script guide. It installs Docker and the latest Nocturne release, and starts Nocturne once DNS works</li>
            <li>Follows the install, waits until HTTPS works, and prints your address</li>
        </ul>
    </details>
    <Callout type="info" title="If anything goes wrong, run it again">
        <p>
            Running the same command a second time is safe. It updates the toolkit, then reuses your
            existing passwords, region and address. To start the installer on the server again
            without touching your data, run the Reinstall command in
            <a href="#manage" class="text-primary hover:underline">Managing the server</a>.
        </p>
    </Callout>

    <StepHeading id="step-3" installStep="3">Step 3: Region, size and DNS</StepHeading>
    <p class="text-muted-foreground mb-4">
        The script lists Azure regions grouped by area, cheapest first, and recommends one.
        <strong>Your health data is stored in the region you choose</strong>, so pick one that meets your
        privacy needs, such as a region in the EU for GDPR.
    </p>
    <p class="text-muted-foreground mb-4">
        It then checks which server sizes your subscription can actually use in that region, and
        offers the cheapest with 2, 4, 6 and 8 GB of memory. 4 GB is recommended. Example estimates
        from the East US 2 price list, November 2026, for the server, disk and IP address together:
    </p>
    <div class="overflow-x-auto mb-4">
        <table class="w-full text-sm text-muted-foreground">
            <thead>
                <tr class="border-b border-border text-left text-foreground">
                    <th class="py-2 pr-4 font-semibold">Memory</th>
                    <th class="py-2 pr-4 font-semibold">Example size</th>
                    <th class="py-2 font-semibold">Per month</th>
                </tr>
            </thead>
            <tbody>
                <tr class="border-b border-border"><td class="py-2 pr-4">2 GB (minimum)</td><td class="py-2 pr-4">Standard_B1ms</td><td class="py-2">about $21</td></tr>
                <tr class="border-b border-border"><td class="py-2 pr-4"><strong>4 GB (recommended)</strong></td><td class="py-2 pr-4">Standard_B2pls_v2 (Arm)</td><td class="py-2"><strong>about $31</strong></td></tr>
                <tr class="border-b border-border"><td class="py-2 pr-4">8 GB</td><td class="py-2 pr-4">Standard_B2ps_v2 (Arm)</td><td class="py-2">about $55</td></tr>
            </tbody>
        </table>
    </div>
    <p class="text-muted-foreground mb-4">
        Prices are estimates. Your bill depends on the region, currency and taxes. The script shows
        the real figures for your region and asks you to confirm before it creates anything.
    </p>
    {#if !guide.host || duckDns}
        <p class="text-muted-foreground {duckDns ? 'mb-8' : 'mb-4'}">
            {#if !guide.host}<strong class="text-foreground">A domain under duckdns.org:</strong>{/if}
            Once the server exists, the script points your DuckDNS name at it with your token. If you
            pressed Enter instead, it tells you the address to put in the <strong>current ip</strong> box
            at duckdns.org.
        </p>
    {/if}
    {#if !duckDns}
        <p class="text-muted-foreground mb-4">
            {#if !guide.host}<strong class="text-foreground">Any other domain:</strong>{/if}
            Once the server exists, the script prints two <strong>A</strong> records. Create them at your
            domain provider, pointing at the IP address it shows:
        </p>
        <CodeBlock code={dnsRecords} class="mb-4" />
        <p class="text-muted-foreground mb-8">
            The second one is a wildcard. It makes every site's subdomain resolve without a record
            each. If you use Cloudflare, leave the proxy off for both records, shown as a gray cloud.
        </p>
    {/if}
    <p class="text-muted-foreground mb-8">
        The script waits until the records work. If you need longer, run the same command again later:
        Nocturne starts by itself as soon as DNS works.
    </p>

    <StepHeading id="step-4" installStep="4">Step 4: Create your first site</StepHeading>
    <p class="text-muted-foreground mb-8">
        When the script finishes, it prints the setup address and offers to open it. If you closed
        the window, open
<SiteLink path="/setup" />
        in a browser. Name your first site and create the owner account, with a passkey or a sign-in
        provider. A passkey is your phone's or computer's built-in unlock. If you choose one,
        register a second device as soon as you can, because there is no password to fall back on.
    </p>

    <h2 class="text-2xl font-bold mt-8 mb-4">Afterwards</h2>
    <ul class="list-disc list-inside space-y-2 text-muted-foreground mb-4">
        <li>
            The generated passwords and keys are never shown on screen. They are saved in
            <code class="text-xs bg-muted/50 px-1.5 py-0.5 rounded">nocturne-azure/secrets/rg-nocturne.env</code>
            on your computer. <strong>Back up this file.</strong> Without it, saved connector credentials
            cannot be recovered.
        </li>
        <li>Nocturne starts again by itself when the server reboots, and Watchtower keeps it up to date.</li>
        <li>
            Nothing backs up your data automatically. In the Azure portal, you can take a snapshot of
            the server's disk, or turn on Azure Backup for the VM, which is charged separately.
        </li>
    </ul>
    <h2 id="manage" class="text-2xl font-bold mt-8 mb-4 scroll-mt-48 md:scroll-mt-36">Managing the server</h2>
    <p class="text-muted-foreground mb-4">
        Run the one-line command again with an action. It downloads the toolkit from GitHub and runs
        it, so it works from any folder. Ssh needs the computer you deployed from, which holds the
        SSH key.
    </p>
    {#each ACTIONS as { action, what } (action)}
        <p class="text-sm text-muted-foreground mb-2">{what}:</p>
        <CodeBlock code={actionCommand(action)} class="mb-4" />
    {/each}

    <h2 data-install-step="next-steps" class="text-2xl font-bold mt-8 mb-4">Next steps</h2>
    <NextSteps />

    <SupportNocturne />
</div>
