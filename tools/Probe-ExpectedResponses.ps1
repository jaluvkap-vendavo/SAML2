<#
    Stress probe for the session-less expected-response store in SAML2.Protocol.Utility.

    The bug this exercises is a race over process-wide static state, so it needs neither IIS
    nor an identity provider. Point it at a build of SAML2.Core and it reports whether the
    store survives concurrent use; point it at a build from before the fix and it should fail.

    Must run under Windows PowerShell 5.1: SAML2.Core references System.IdentityModel and
    System.ServiceModel and will not load on PowerShell Core.

    Exit code 0 when both scenarios pass, 1 otherwise.

    Example:
      powershell -NoProfile -File tools/Probe-ExpectedResponses.ps1 -AssemblyPath src/SAML2.Core/bin/Release/SAML2.Core.dll
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $AssemblyPath,

    # Scenario 1: concurrent adds. The tear happens while the backing store grows, so this
    # wants to be large enough to force many resizes.
    [int] $Iterations = 200000,

    # Scenario 2: rounds of "one id, many threads racing to consume it".
    [int] $Rounds = 2000,

    [int] $Threads = [Math]::Max(8, [Environment]::ProcessorCount * 2),

    # A corrupted HashSet can spin forever instead of throwing, so neither scenario is allowed
    # to run unbounded.
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq "Core") {
    throw "Run this under Windows PowerShell 5.1 (powershell.exe), not PowerShell Core: SAML2.Core is a .NET Framework assembly."
}

$resolved = (Resolve-Path $AssemblyPath).Path
$identity = [Reflection.AssemblyName]::GetAssemblyName($resolved).Version
$fileVersion = (Get-Item $resolved).VersionInfo.FileVersion

Write-Host "Assembly : $resolved"
Write-Host "Identity : $identity (file $fileVersion)"
Write-Host "Threads  : $Threads"
Write-Host ""

$source = @"
using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;
using SAML2;
using SAML2.Config;
using SAML2.Logging;
using SAML2.Protocol;

public static class ExpectedResponsesProbe
{
    // The static initializer of Utility asks LoggerProvider for a logger, and the lazy factory
    // dereferences LoggerProvider.Configuration. Outside a hosted application nobody has set it,
    // so the first touch of Utility would fail with a TypeInitializationException. An empty
    // configuration leaves LoggingFactoryType empty, which selects NoLoggingLoggerFactory.
    public static void Initialize()
    {
        LoggerProvider.Configuration = new Saml2Configuration();
    }

    public class AddResult
    {
        public bool TimedOut;
        public int Added;
        public int Failed;
        public string FirstFailure;
        public string FirstFailureStack;
        public long ElapsedMs;
    }

    public class ConsumeResult
    {
        public bool TimedOut;
        public int Rounds;
        public int ConsumedTwiceOrMore;
        public int NeverConsumed;
        public string FirstUnexpectedFailure;
        public long ElapsedMs;
    }

    // Concurrent AddExpectedResponseId. Before the fix this corrupts the static HashSet and
    // surfaces as IndexOutOfRangeException in HashSet.AddIfNotPresent - or hangs.
    public static AddResult HammerAdd(int iterations, int threads, int timeoutSeconds)
    {
        var result = new AddResult();
        var failures = new ConcurrentQueue<Exception>();
        int added = 0;
        var watch = System.Diagnostics.Stopwatch.StartNew();

        var worker = Task.Run(() =>
        {
            var options = new ParallelOptions { MaxDegreeOfParallelism = threads };
            Parallel.For(0, iterations, options, i =>
            {
                try
                {
                    Utility.AddExpectedResponseId("probe-" + Guid.NewGuid().ToString("N"));
                    Interlocked.Increment(ref added);
                }
                catch (Exception ex)
                {
                    failures.Enqueue(ex);
                }
            });
        });

        try
        {
            result.TimedOut = !worker.Wait(TimeSpan.FromSeconds(timeoutSeconds));
        }
        catch (AggregateException aggregate)
        {
            // Anything that escaped the loop body, plus faults raised by Parallel.For itself.
            foreach (var inner in aggregate.Flatten().InnerExceptions)
            {
                failures.Enqueue(inner);
            }
        }

        watch.Stop();

        result.ElapsedMs = watch.ElapsedMilliseconds;
        result.Added = added;
        result.Failed = failures.Count;

        Exception first;
        if (failures.TryDequeue(out first))
        {
            result.FirstFailure = first.GetType().FullName + ": " + first.Message;
            result.FirstFailureStack = first.StackTrace;
        }

        return result;
    }

    // One id, many threads released together, all claiming the same InResponseTo. Exactly one
    // may be accepted: more than one is the replay hole that Contains-then-Remove leaves open,
    // none at all would mean a legitimate login was rejected.
    public static ConsumeResult HammerConsume(int rounds, int threads, int timeoutSeconds)
    {
        var result = new ConsumeResult();
        var unexpected = new ConcurrentQueue<Exception>();
        int consumedTwice = 0;
        int neverConsumed = 0;
        int completedRounds = 0;
        var watch = System.Diagnostics.Stopwatch.StartNew();

        var worker = Task.Run(() =>
        {
            for (var round = 0; round < rounds; round++)
            {
                var id = "probe-" + Guid.NewGuid().ToString("N");
                Utility.AddExpectedResponseId(id);

                var accepted = 0;
                // Real threads plus a barrier, so the contention is genuine. A thread pool
                // cannot be relied on to release all participants of a barrier at once.
                var gate = new Barrier(threads);
                var crew = new Thread[threads];

                for (var t = 0; t < threads; t++)
                {
                    crew[t] = new Thread(() =>
                    {
                        var document = new XmlDocument();
                        var element = document.CreateElement("Response");
                        element.SetAttribute("InResponseTo", id);

                        gate.SignalAndWait();

                        try
                        {
                            Utility.CheckReplayAttack(element, true, null);
                            Interlocked.Increment(ref accepted);
                        }
                        catch (Saml20Exception)
                        {
                            // Expected for every thread that did not win the id.
                        }
                        catch (Exception ex)
                        {
                            unexpected.Enqueue(ex);
                        }
                    });
                    crew[t].IsBackground = true;
                    crew[t].Start();
                }

                foreach (var thread in crew)
                {
                    thread.Join();
                }

                gate.Dispose();

                if (accepted > 1) { Interlocked.Increment(ref consumedTwice); }
                else if (accepted == 0) { Interlocked.Increment(ref neverConsumed); }

                Interlocked.Increment(ref completedRounds);
            }
        });

        try
        {
            result.TimedOut = !worker.Wait(TimeSpan.FromSeconds(timeoutSeconds));
        }
        catch (AggregateException aggregate)
        {
            foreach (var inner in aggregate.Flatten().InnerExceptions)
            {
                unexpected.Enqueue(inner);
            }
        }

        watch.Stop();

        result.ElapsedMs = watch.ElapsedMilliseconds;
        result.Rounds = completedRounds;
        result.ConsumedTwiceOrMore = consumedTwice;
        result.NeverConsumed = neverConsumed;

        Exception first;
        if (unexpected.TryDequeue(out first))
        {
            result.FirstUnexpectedFailure = first.GetType().FullName + ": " + first.Message;
        }

        return result;
    }
}
"@

# The probe has to be compiled to disk next to SAML2.Core rather than in memory. An in-memory
# assembly is bound by identity from the host's application base - powershell.exe's own
# directory - where SAML2.Core does not exist, so calling into it fails with a FileNotFound for
# "SAML2.Core, Version=1.0.0.0". Assembly.LoadFrom resolves a dependency from the directory of
# the assembly that needs it, which is exactly what is wanted here.
$probeAssembly = Join-Path (Split-Path $resolved -Parent) "ExpectedResponsesProbe.dll"
if (Test-Path $probeAssembly) { Remove-Item $probeAssembly -Force }

Add-Type -TypeDefinition $source -ReferencedAssemblies $resolved, "System.Xml.dll" -OutputAssembly $probeAssembly -ErrorAction Stop
[Reflection.Assembly]::LoadFrom($probeAssembly) | Out-Null

[ExpectedResponsesProbe]::Initialize()

$failed = $false

Write-Host "1) $Iterations concurrent AddExpectedResponseId calls"
$add = [ExpectedResponsesProbe]::HammerAdd($Iterations, $Threads, $TimeoutSeconds)

if ($add.TimedOut) {
    Write-Host "   TIMED OUT after $TimeoutSeconds s - a corrupted store can spin instead of throwing." -ForegroundColor Red
    Write-Host "   Added $($add.Added) of $Iterations before giving up. Kill this process." -ForegroundColor Red
    $failed = $true
} elseif ($add.Failed -gt 0) {
    Write-Host "   FAILED: $($add.Failed) of $Iterations calls threw in $($add.ElapsedMs) ms" -ForegroundColor Red
    Write-Host "   $($add.FirstFailure)" -ForegroundColor Red
    Write-Host "$($add.FirstFailureStack)" -ForegroundColor DarkGray
    $failed = $true
} else {
    Write-Host "   ok - $($add.Added) calls, no exception, $($add.ElapsedMs) ms" -ForegroundColor Green
}

Write-Host ""
Write-Host "2) $Rounds rounds of $Threads threads racing to consume one InResponseTo"
$consume = [ExpectedResponsesProbe]::HammerConsume($Rounds, $Threads, $TimeoutSeconds)

if ($consume.TimedOut) {
    Write-Host "   TIMED OUT after $TimeoutSeconds s at round $($consume.Rounds). Kill this process." -ForegroundColor Red
    $failed = $true
} else {
    if ($consume.ConsumedTwiceOrMore -gt 0) {
        Write-Host "   FAILED: $($consume.ConsumedTwiceOrMore) of $($consume.Rounds) rounds accepted the same id more than once (replay)" -ForegroundColor Red
        $failed = $true
    }
    if ($consume.NeverConsumed -gt 0) {
        Write-Host "   FAILED: $($consume.NeverConsumed) of $($consume.Rounds) rounds accepted nobody (a valid response would be rejected)" -ForegroundColor Red
        $failed = $true
    }
    if ($consume.FirstUnexpectedFailure) {
        Write-Host "   FAILED: unexpected exception - $($consume.FirstUnexpectedFailure)" -ForegroundColor Red
        $failed = $true
    }
    if (-not $failed) {
        Write-Host "   ok - every round accepted exactly one thread, $($consume.ElapsedMs) ms" -ForegroundColor Green
    }
}

Write-Host ""
if ($failed) {
    Write-Host "PROBE FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "PROBE PASSED" -ForegroundColor Green
exit 0
