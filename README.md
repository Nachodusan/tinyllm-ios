# tinyllm-ios

A single tokens/sec figure from a phone is a burst number.

Every on-device inference benchmark publishes one throughput figure. That
figure is almost always the first generation, on a cool device, with the whole
thermal budget unspent. Run the same model back to back for under four minutes
and it is 39% lower. Nothing in the README says which one you are reading.

So this measures both, on a real iPhone, and separates them.

MLX Swift, Qwen2.5-0.5B-Instruct-4bit, iPhone 16 (`iPhone17,3`), iOS 26.6.1.
150 generations back to back, 128-token cap, no pause between them.

---

## The result

| | cold device | after 3 min idle |
|---|---|---|
| **burst** — run 1 | 108.85 tok/s | 107.40 tok/s |
| **sustained** — last third | **66.32 tok/s** | **61.11 tok/s** |
| retained | 61% | 57% |
| time to first token | 80 → 105 ms | 95 → 115 ms |
| `thermalState` leaves `nominal` | run 36 (46 s) | run 1 |
| worst `thermalState` | serious | serious |

The published number for this model on this phone would be **109 tok/s**. What
it holds under sustained load is **66**. Both are correct; only one of them
describes using the thing.

It does settle rather than fall forever: the last 30 runs average 66.03 tok/s
with a 2.04 spread. That plateau is the device's floor, and it takes 60
seconds of continuous work to reach within 5% of it.

Full per-run data for all three runs below is in [`evidence/`](evidence/).

## Two explanations, and the experiment that separates them

Throughput declining across a batch has a second explanation that looks
identical from inside one batch: the process is accumulating something — a
growing KV cache, an unbounded MLX buffer pool, a leak. Publishing
"thermal throttling" without excluding that is a guess.

The experiment is to idle and run the identical batch again:

- **Recovery to the original burst figure** → the device. Three minutes of
  idling restored **99%** of it (108.85 → 107.40 tok/s).
- **A second batch opening where the first one ended** → the code.

It recovered. Memory also stayed flat at 377–404 MB across all 300
generations, which independently rules out the leak. So the decay is the
phone, and `evidence/iphone16-soak-rewarmed.json` is what that costs to
establish.

The rewarmed batch is the more useful half of the result anyway. It opens at
full speed but reports thermal pressure from **run 1** instead of run 36, and
settles 8% lower than the cold batch. A phone that has been working recently —
which is the normal condition of a phone — gets to its floor faster and the
floor is lower.

## `ProcessInfo.thermalState` is a lagging indicator

This is the part that surprised me. By the time iOS first reported anything
above `nominal`, throughput was already at **74% of burst**. A quarter of the
performance was gone while the only API available for noticing said everything
was fine.

```
run  1   108.85 tok/s   nominal
run 10    92.57 tok/s   nominal      -15%
run 20    84.98 tok/s   nominal      -22%
run 30    81.21 tok/s   nominal      -25%
run 36    80.24 tok/s   fair         <- the OS says something for the first time
run 50    74.30 tok/s   serious
run 90    64.32 tok/s   serious
run150    65.73 tok/s   serious
```

`thermalState` is the right tool for deciding whether to stop work. It is the
wrong tool for deciding whether work is being slowed down, and an app that
only reduces quality when the state changes has already shipped a quarter of
its degradation to the user.

## The guard, and the run that made it necessary

The first measurement taken here was 12 runs, because 12 runs is what fits in
a demo. It reported:

```
burst 109.11 · sustained 93.44 · retained 86%
worst thermal state: nominal · throttled: never
```

Every figure is arithmetically correct. The conclusion it invites — that this
device holds its throughput — is false by 39%. The run simply ended before the
phone got warm.

Nothing in those numbers says so, so the report says it itself:

```swift
public var reachedEquilibrium: Bool   // did throughput stop falling?
public var warnings: [String]         // why this report might be lying
public var isTrustworthy: Bool        // warnings.isEmpty
```

`reachedEquilibrium` compares the last sixth of the run against the sixth
before it and is false if the difference exceeds 2%. On the 12-run sweep it
emits three warnings, including the one that matters:

> the run ended before the OS reported any thermal pressure, so "never
> throttled" here means "not yet"

The app shows these above the numbers, not below them. That file is still in
[`evidence/iphone16-12runs.json`](evidence/iphone16-12runs.json) — a report
being wrong is the reason to keep it, not to delete it.

## Why these choices

**Back to back, no pause.** Pausing between generations lets the phone cool
and produces a number it cannot hold under load. That is the whole mechanism
by which burst figures get published, so the loop refuses to do it.

**`phys_footprint`, not `resident_size`.** It is the number iOS uses when
deciding whether to kill the app, which is the only memory figure that
decides anything on a phone.

**Sustained is the last third, not a global mean.** A mean over the whole run
is a weighted average of a device state that no longer exists and one that
does. The tail is the state the device is actually in.

**A real device, never the simulator.** The simulator runs on the Mac's CPU
and GPU, with a laptop's heat sink. It will give you a number. The number is
about your Mac.

**Greedy decoding (`temperature: 0`).** Sampling is not being measured and
varying output length across runs would add noise to a throughput figure for
no reason.

## Running it

```bash
xcodegen generate
open TinyLLM.xcodeproj
```

Then pick your device and run. The first launch downloads ~335 MB of weights
from Hugging Face and caches them.

Headless, for numbers you want to repeat rather than screenshot:

```bash
xcrun devicectl device install app --device <udid> <path-to-TinyLLM.app>
xcrun devicectl device process launch --device <udid> --console \
  -e '{"TINYLLM_HEADLESS":"1","TINYLLM_RUNS":"150","TINYLLM_COOLDOWN":"180"}' \
  ar.dusan.tinyllm
```

`TINYLLM_COOLDOWN` is the recovery experiment: it runs the batch, idles, and
runs the identical batch again. Progress and the full JSON report go to
stdout.

The app disables the idle timer while benchmarking. It has to — a 150-run
sweep outlasts the default auto-lock, and when the screen sleeps iOS suspends
the app and drops the USB session. Two runs died that way before that line
existed.

### Tests

```bash
swift test
```

Nineteen tests, all on the reporting rather than the model. Seven of them run
against the three real reports in `evidence/`, including the 12-run sweep — a
guard written against invented data would not have caught the case that
produced it.

## What this is not

- **Not a model comparison.** One 0.5B model at 4-bit. Larger models shift the
  balance between memory bandwidth and compute, and the thermal picture with
  it.
- **Not a device comparison.** One iPhone 16, one iOS version, one ambient
  temperature, in a case. Thermal behaviour is sensitive to all four, and the
  61% figure should not be read as a property of A18 silicon.
- **Not a claim about why.** `thermalState` says the OS saw thermal pressure
  and the recovery test says it was the device, not the process. Whether the
  mechanism is GPU clock, CPU clock, memory bandwidth or power delivery is
  not visible from inside an app, and this does not guess.

## Licence

[MIT](LICENSE).
