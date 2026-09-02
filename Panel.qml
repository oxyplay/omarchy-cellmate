import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.oxyplay.cellmate"
  ipcTarget: "io.github.oxyplay.cellmate"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0

  // All present laptop batteries, in native-path order. UPower's DisplayDevice
  // only surfaces a single battery, so aggregate over the device list instead.
  readonly property var batteries: {
    var out = []
    var devices = UPower.devices.values
    for (var i = 0; i < devices.length; ++i) {
      var d = devices[i]
      if (d && d.type === UPowerDeviceType.Battery && d.isPresent) out.push(d)
    }
    out.sort(function(a, b) { return String(a.nativePath).localeCompare(String(b.nativePath)) })
    return out
  }

  readonly property real totalEnergy: {
    var sum = 0
    for (var i = 0; i < batteries.length; ++i) sum += batteries[i].energy
    return sum
  }

  readonly property real totalCapacity: {
    var sum = 0
    for (var i = 0; i < batteries.length; ++i) sum += batteries[i].energyCapacity
    return sum
  }

  readonly property real totalRate: {
    var sum = 0
    for (var i = 0; i < batteries.length; ++i) sum += Math.abs(batteries[i].changeRate)
    return sum
  }

  readonly property bool anyDischarging: {
    for (var i = 0; i < batteries.length; ++i)
      if (batteries[i].state === UPowerDeviceState.Discharging) return true
    return false
  }

  readonly property bool anyCharging: {
    for (var i = 0; i < batteries.length; ++i)
      if (batteries[i].state === UPowerDeviceState.Charging) return true
    return false
  }

  readonly property bool allFullyCharged: {
    var present = false
    for (var i = 0; i < batteries.length; ++i) {
      present = true
      if (batteries[i].state !== UPowerDeviceState.FullyCharged) return false
    }
    return present
  }

  // Synthetic device mirroring UPower's DisplayDevice aggregation: summed
  // energy/capacity, state derived from the individual batteries.
  readonly property var aggregateDevice: {
    var state = UPowerDeviceState.Unknown
    if (allFullyCharged) state = UPowerDeviceState.FullyCharged
    else if (anyDischarging) state = UPowerDeviceState.Discharging
    else if (anyCharging) state = UPowerDeviceState.Charging
    return {
      isPresent: batteries.length > 0,
      type: UPowerDeviceType.Battery,
      state: state,
      percentage: totalCapacity > 0 ? totalEnergy / totalCapacity : 0,
      changeRate: totalRate
    }
  }

  // Whole-machine draw/charge estimate. Rate is averaged over the last ~10
  // minutes of history (when available) so short CPU bursts don't wiggle the
  // ETA; falls back to the instantaneous rate otherwise.
  readonly property real timeEstimateSeconds: {
    var rate = root.totalRate
    // Average only samples taken while discharging/charging in the same
    // direction as now; mixing older opposite-direction rates after an
    // AC <-> battery switch would skew the ETA for minutes.
    var want = root.anyDischarging ? 1 : 0
    var sum = 0
    var cnt = 0
    for (var i = history.length - 1; i >= 0 && cnt < 20; --i) {
      var e = history[i]
      if (e.b !== want) continue
      sum += e.r
      cnt++
    }
    if (cnt >= 3) {
      var avg = sum / cnt
      if (avg > 0.05) rate = avg
    }
    if (rate <= 0.05) return 0
    if (root.anyDischarging) return totalEnergy / rate * 3600
    // Charging (or topping off on AC with no Flowing state yet): time to full
    // from remaining capacity. batteryFlowIdle (full/holding) is handled by
    // the callers before they format this, so reaching here means charge flow.
    var missing = totalCapacity - totalEnergy
    if (missing > 0.1 && !UPower.onBattery) return missing / rate * 3600
    return 0
  }

  // sysfs-only details (charge thresholds, cycle counts) keyed by battery name.
  property var batteryDetails: ({})

  function chargeLimitLabel() {
    // Charge-control threshold range across batteries, e.g. "75-80%" or "80%".
    var ends = []
    var starts = []
    for (var name in root.batteryDetails) {
      var d = root.batteryDetails[name]
      if (!d || !d.threshold) continue
      var v = Number(d.threshold)
      if (v >= 100) continue
      ends.push(v)
      if (d["threshold-start"]) starts.push(Number(d["threshold-start"]))
    }
    if (ends.length === 0) return ""
    var min = Math.min.apply(null, ends)
    var max = Math.max.apply(null, ends)
    var label = max === min ? min + "%" : min + "-" + max + "%"
    var uniformStart = starts.length > 0 && starts.every(function(s) { return s === starts[0] })
    if (uniformStart && starts[0] < min) return starts[0] + "-" + label
    return label
  }

  function updateBatteryDetails(raw) {
    var s = String(raw || "")
    if (s.length > 4096) s = s.substring(0, 4096)
    var next = {}
    var nbat = 0
    var lines = s.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 3) continue
      var key = parts[0]
      if (key !== "cycles" && key !== "threshold" && key !== "threshold-start") continue
      var bat = Model.safeText(parts[1], 16)
      if (!/^BAT[A-Za-z0-9_]*$/.test(bat)) continue
      var val = Number(parts[2])
      if (!isFinite(val) || val < 0 || val > 99999) continue
      if (!next[bat]) {
        if (nbat >= 8) continue
        next[bat] = {}
        nbat++
      }
      next[bat][key] = String(Math.round(val))
    }
    batteryDetails = next
  }

  // ---- History sampling (chart) ----
  // 30s samples, up to 24h. Persisted to ~/.local/state/omarchy/power-history.log
  // (one "t p r b" line per sample, capped at 24h) so the chart survives shell
  // restarts; the file is loaded back at startup through history.py.
  property var history: []
  function pluginPath(name) {
    var u = String(Qt.resolvedUrl(name))
    if (u.indexOf("file://") === 0) return decodeURIComponent(u.substring(7))
    return name
  }

  function timeoutCmd(sec, argv) {
    // GNU timeout: own process group, SIGTERM at sec, SIGKILL 1s later.
    return ["timeout", "--kill-after=1", String(sec)].concat(argv)
  }

  function startExclusive(proc) {
    if (!proc || proc.running) return
    proc.running = true
  }
  property string chartMode: "draw"    // "pct" | "draw"
  property bool chartHover: false
  property real chartHoverX: -1
  property int chartWindowHours: 6    // 1 | 6 | 24
  readonly property int historyWindowPoints: Math.round(chartWindowHours * 3600 / 30)

  function sampleHistory() {
    var now = new Date().getTime() / 1000
    var last = history.length > 0 ? history[history.length - 1] : null
    if (last && now - last.t < 25) return
    var next
    // Seed two identical points so the chart draws immediately after a shell
    // restart instead of showing "collecting data…" for the first minute.
    if (history.length === 0) {
      var b = root.anyDischarging ? 1 : 0
      next = [
        { t: now - 1, b: b, p: root.batteryFraction, r: root.totalRate },
        { t: now, b: b, p: root.batteryFraction, r: root.totalRate }
      ]
    } else {
      next = history.concat([{ t: now, b: root.anyDischarging ? 1 : 0, p: root.batteryFraction, r: root.totalRate }])
    }
    if (next.length > 2880) next = next.slice(next.length - 2880)
    history = next
    if (chart) chart.requestPaint()

    // Persist the newest sample; the shell script also caps the file at 2 days.
    var lastEntry = next[next.length - 1]
    if (!histAppend.running) {
      var p = Math.max(0, Math.min(1, lastEntry.p))
      var r = Math.max(0, Math.min(9999, lastEntry.r))
      var b = lastEntry.b === 0 || lastEntry.b === 1 ? String(lastEntry.b) : "-1"
      histAppend.command = root.timeoutCmd(3, ["python3", root.pluginPath("history.py"), "append",
        String(Math.round(lastEntry.t)) + " " + p.toFixed(4) + " " + r.toFixed(4) + " " + b])
      histAppend.running = true
    }
  }

  function cycleChartWindow() {
    if (chartWindowHours === 1) chartWindowHours = 6
    else if (chartWindowHours === 6) chartWindowHours = 24
    else chartWindowHours = 1
    if (chart) chart.requestPaint()
  }

  function chartValues() {
    var pts = []
    var start = history.length - historyWindowPoints
    if (start < 0) start = 0
    for (var i = start; i < history.length; ++i) {
      var e = history[i]
      pts.push(chartMode === "pct" ? e.p : e.r)
    }
    return pts
  }

  function cssColor(color, alpha) {
    return "rgba(" + Math.round(color.r * 255) + "," + Math.round(color.g * 255) + "," + Math.round(color.b * 255) + "," + alpha + ")"
  }

  function paintChart(c) {
    var ctx = c.getContext("2d")
    var w = c.width
    var h = c.height
    ctx.clearRect(0, 0, w, h)
    var fg = root.bar ? root.bar.foreground : Color.foreground
    var vals = chartValues()
    var n = vals.length
    if (n < 2) {
      ctx.fillStyle = cssColor(fg, 0.5)
      ctx.font = "10px sans-serif"
      ctx.textAlign = "center"
      ctx.fillText("collecting data…", w / 2, h / 2)
      return
    }

    var pad = 0
    var maxV = -Infinity
    var minV = Infinity
    for (var i = 0; i < n; ++i) {
      if (vals[i] > maxV) maxV = vals[i]
      if (vals[i] < minV) minV = vals[i]
    }
    if (!isFinite(maxV)) { maxV = 1; minV = 0 }
    else if (chartMode === "draw") {
      minV = 0
      if (maxV <= 0) maxV = 1
      maxV *= 1.15
    } else {
      // Zoom the level chart around the data so small changes stay visible.
      var span = maxV - minV
      var padV = Math.max(span * 0.3, 0.01)
      maxV += padV
      minV = Math.max(0, minV - padV)
    }

    var xs = []
    var ys = []
    for (i = 0; i < n; ++i) {
      xs.push(pad + (w - 2 * pad) * i / (n - 1))
      ys.push(h - pad - (vals[i] - minV) / (maxV - minV) * (h - 2 * pad))
    }

    // Smooth line through midpoints.
    ctx.beginPath()
    ctx.moveTo(xs[0], ys[0])
    for (i = 1; i < n - 1; ++i) {
      var xc = (xs[i] + xs[i + 1]) / 2
      var yc = (ys[i] + ys[i + 1]) / 2
      ctx.quadraticCurveTo(xs[i], ys[i], xc, yc)
    }
    ctx.lineTo(xs[n - 1], ys[n - 1])
    ctx.strokeStyle = cssColor(fg, 1.0)
    ctx.lineWidth = 2.5
    ctx.stroke()

    // Faded area fill under the curve.
    ctx.lineTo(xs[n - 1], h)
    ctx.lineTo(xs[0], h)
    ctx.closePath()
    var grad = ctx.createLinearGradient(0, 0, 0, h)
    grad.addColorStop(0, cssColor(fg, 0.22))
    grad.addColorStop(1, cssColor(fg, 0.02))
    ctx.fillStyle = grad
    ctx.fill()

    // Time labels: oldest sample (or window start) left, now right.
    var pad2 = function(v) { return String(v).padStart(2, "0") }
    var t0 = new Date(history[Math.max(0, history.length - historyWindowPoints)].t * 1000)
    var t1 = new Date(history[history.length - 1].t * 1000)
    ctx.font = "9px sans-serif"
    ctx.fillStyle = cssColor(fg, 0.5)
    ctx.textAlign = "left"
    ctx.fillText(pad2(t0.getHours()) + ":" + pad2(t0.getMinutes()), pad, h - 2)
    ctx.textAlign = "right"
    ctx.fillText(pad2(t1.getHours()) + ":" + pad2(t1.getMinutes()), w - pad, h - 2)

    // Current value chip.
    ctx.textAlign = "right"
    ctx.fillStyle = cssColor(fg, 0.9)
    ctx.font = "10px sans-serif"
    ctx.fillText(chartMode === "pct"
      ? Math.round(vals[n - 1] * 100) + "%"
      : vals[n - 1].toFixed(1) + "W", w - pad, pad + 8)

    // Hover inspector: crosshair + dot + "time · value" label under the cursor.
    if (root.chartHover && root.chartHoverX >= 0 && n >= 2) {
      var hi = Math.round((root.chartHoverX - pad) / (w - 2 * pad) * (n - 1))
      if (hi < 0) hi = 0
      if (hi > n - 1) hi = n - 1

      ctx.strokeStyle = cssColor(fg, 0.35)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(xs[hi], pad)
      ctx.lineTo(xs[hi], h - pad)
      ctx.stroke()

      ctx.beginPath()
      ctx.arc(xs[hi], ys[hi], 3.5, 0, 2 * Math.PI)
      ctx.fillStyle = cssColor(fg, 1.0)
      ctx.fill()

      var hEntry = history[history.length - n + hi]
      var hDate = new Date(hEntry.t * 1000)
      var hVal = vals[hi].toFixed(1) + "W"
      var hText = pad2(hDate.getHours()) + ":" + pad2(hDate.getMinutes()) + " · " + hVal
      ctx.font = "10px sans-serif"
      ctx.fillStyle = cssColor(fg, 0.9)
      ctx.textAlign = "center"
      var cx = Math.max(pad + 55, Math.min(w - pad - 55, xs[hi]))
      ctx.fillText(hText, cx, h - pad - 6)
    }
  }

  // ---- Top energy consumers ----
  // The script reports each process's current CPU share (over a 1s window)
  // plus TOTAL across all processes. When the battery is discharging we split
  // the measured battery draw between processes by that share, so the numbers
  // are watts and sum to (roughly) the real draw. On AC there is no measurable
  // total, so the raw CPU share is shown instead.
  property var topConsumers: []
  property real consumersTotalCpu: 1
  readonly property bool energyAttribution: root.anyDischarging && root.totalRate > 0.5

  function updateHistoryFromFile(raw) {
    var s = String(raw || "")
    if (s.length > 200000) s = s.substring(s.length - 200000)
    var lines = s.split("\n")
    var pts = []
    for (var i = 0; i < lines.length; ++i) {
      var line = lines[i].trim()
      if (!line || line.length > 80) continue
      var f = line.split(" ")
      if (f.length < 3) continue
      var t = Number(f[0])
      var p = Number(f[1])
      var r = Number(f[2])
      if (!isFinite(t) || t < 1e9 || t > 2e10) continue
      if (!isFinite(p) || p < 0 || p > 1) continue
      if (!isFinite(r) || r < 0 || r > 9999) continue
      var b = f.length > 3 ? Number(f[3]) : -1
      if (b !== 0 && b !== 1) b = -1
      pts.push({ t: t, b: b, p: p, r: r })
      if (pts.length > 2880) pts = pts.slice(pts.length - 2880)
    }
    if (pts.length > 1) history = pts
  }

  function updateTopConsumers(raw) {
    var s = String(raw || "")
    if (s.length > 4096) s = s.substring(0, 4096)
    var out = []
    var lines = s.split("\n")
    var total = 0
    for (var i = 0; i < lines.length; ++i) {
      var line = lines[i]
      if (!line) continue
      var t = line.split("\t")
      if (t.length < 2) continue
      var cpu = Number(t[1])
      if (!isFinite(cpu) || cpu < 0 || cpu > 9999) continue
      if (t[0] === "TOTAL") {
        total = cpu
        continue
      }
      if (out.length >= 3) continue
      var name = Model.safeText(t[0], 32)
      if (!name) continue
      out.push({ name: name, cpu: cpu })
    }
    topConsumers = out
    consumersTotalCpu = total > 0 ? total : 1
  }

  function consumerValue(cpu) {
    if (root.energyAttribution) return (root.totalRate * cpu / root.consumersTotalCpu).toFixed(1) + "W"
    return cpu.toFixed(1) + "%"
  }

  readonly property bool batteryPresent: {
    var device = root.aggregateDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = root.aggregateDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = root.aggregateDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = root.aggregateDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = root.aggregateDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = root.aggregateDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = root.aggregateDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = root.aggregateDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    sampleHistory()
    startExclusive(profilesProc)
    startExclusive(detailsProc)
    startExclusive(topProc)
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    profile = Model.safeText(profile, 32)
    if (!/^[a-z0-9_-]+$/.test(profile) || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "io.github.oxyplay.cellmate"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  // sysfs-only battery details (charge thresholds, cycle counts) per battery.
  Process {
    id: detailsProc
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
    command: root.timeoutCmd(3, ["sh", "-c",
      "c=0; for d in /sys/class/power_supply/BAT*; do " +
      "[ -d \"$d\" ] || continue; c=$((c+1)); [ \"$c\" -gt 8 ] && break; " +
      "b=${d##*/}; case \"$b\" in BAT[A-Za-z0-9_]*) ;; *) continue ;; esac; " +
      "[ ${#b} -gt 16 ] && continue; " +
      "for spec in cycle_count:cycles charge_control_end_threshold:threshold charge_control_start_threshold:threshold-start; do " +
      "f=${spec%%:*}; n=${spec##*:}; [ -r \"$d/$f\" ] || continue; " +
      "v=$(dd if=\"$d/$f\" bs=16 count=1 2>/dev/null | tr -cd '0-9'); " +
      "[ -n \"$v\" ] && printf '%s\\t%s\\t%s\\n' \"$n\" \"$b\" \"$v\"; " +
      "done; done"])
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateBatteryDetails(text) }
  }
  // Load persisted history back (newest 24h) at shell startup.
  Process {
    id: histLoad
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
    running: true
    command: root.timeoutCmd(3, ["python3", root.pluginPath("history.py"), "load"])
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateHistoryFromFile(text) }
  }

  // Appends one "t p r b" line per sample; see sampleHistory().
  Process {
    id: histAppend
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
  }

  // Top consumers: current CPU share over a 1s window (delta of utime+stime
  // from /proc/<pid>/stat — ps pcpu is a lifetime average and lies), normalized
  // into watts of the measured battery draw when discharging.
  Process {
    id: topProc
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
    command: root.timeoutCmd(5, ["sh", root.pluginPath("topconsumers.sh")])
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateTopConsumers(text) }
  }

  Process {
    id: profilesProc
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
    command: root.timeoutCmd(3, ["sh", "-c", "omarchy-powerprofiles-list --active-state | head -c 4096"])
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: actionProc
    clearEnvironment: true
    environment: ({
      PATH: "/run/current-system/sw/bin:/usr/bin:/bin",
      HOME: null,
      XDG_STATE_HOME: null,
    })
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Feed the chart even while the panel is closed so it has history on open.
  Timer {
    interval: 30000
    running: root.batteryPresent
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sampleHistory()
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: Math.round(root.batteryFraction * 100) + "% · " + (root.totalRate > 0.05 ? Model.formatTime(root.timeEstimateSeconds) : (root.batteryFlowIdle ? "Full" : "-"))
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: (root.heroStatusText || "").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: Math.round(root.batteryFraction * 100) + "%"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Batteries ----------
        // One row per present battery: mini progress bar + % · state · cycles.
        // Shown as soon as UPower reports devices; cycle counts arrive from the
        // sysfs sweep a moment later and slot in without collapsing the layout.
        Column {
          visible: root.batteryPresent
          width: parent.width
          spacing: Style.space(7)

          Repeater {
            model: root.batteries
            delegate: Item {
              required property var modelData
              width: parent.width
              height: Style.space(14)

              Text {
                id: cellLabel
                textFormat: Text.PlainText
                text: Model.safeText(String(modelData.nativePath), 64)
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
              }

              Text {
                id: cellInfo
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  var t = Math.round(modelData.percentage * 100) + "%"
                  if (Math.abs(modelData.changeRate) >= 0.05) t += " · " + Model.rateSigned(modelData, root.upowerStates())
                  return t
                }
              }

              Rectangle {
                id: cellTrack
                anchors.left: cellLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.right: cellInfo.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
              }

              Rectangle {
                anchors.left: cellTrack.left
                anchors.verticalCenter: cellTrack.verticalCenter
                height: cellTrack.height
                radius: cellTrack.radius
                color: root.batteryFillColor
                width: Math.max(cellTrack.height, cellTrack.width * Math.max(0, Math.min(1, modelData.percentage)))
              }
            }
          }
        }

        // ---------- Totals ----------
        Row {
          visible: root.batteryPresent
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: Model.rateLabel(root.aggregateDevice)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.totalRate > 0.05 ? Model.formatTime(root.timeEstimateSeconds) : (root.batteryFlowIdle ? "Full" : "-")
            color: root.bar.foreground
            opacity: 0.7
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

        }

        // ---------- History chart ----------
        Column {
          visible: root.batteryPresent
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            height: Style.space(56)

            Canvas {
              id: chart
              anchors.fill: parent
              onPaint: root.paintChart(this)
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              onPositionChanged: function(mouse) {
                root.chartHover = true
                root.chartHoverX = mouse.x
                chart.requestPaint()
              }
              onExited: {
                root.chartHover = false
                chart.requestPaint()
              }
            }
          }
        }

        // ---------- Top consumers ----------
        Column {
          visible: root.batteryPresent
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "EST. TOP CONSUMERS"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Repeater {
            model: root.topConsumers
            delegate: Item {
              required property var modelData
              width: parent.width
              height: Style.space(12)

              Text {
                id: consName
                textFormat: Text.PlainText
                text: Model.safeText(modelData.name, 32)
                elide: Text.ElideRight
                width: Style.space(110)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: consTrack
                anchors.left: consName.right
                anchors.leftMargin: Style.space(6)
                anchors.right: consPct.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(3)
                radius: height / 2
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
              }

              // Normalize against the top consumer so the biggest bar is full-width.
              Rectangle {
                anchors.left: consTrack.left
                anchors.verticalCenter: consTrack.verticalCenter
                height: consTrack.height
                radius: consTrack.radius
                color: root.batteryFillColor
                width: Math.max(consTrack.height, topConsumers.length > 0 ? consTrack.width * modelData.cpu / topConsumers[0].cpu : 0)
              }

              Text {
                id: consPct
                textFormat: Text.PlainText
                text: root.consumerValue(modelData.cpu)
                width: Style.space(52)
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: Model.safeText(String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1), 24)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

}
