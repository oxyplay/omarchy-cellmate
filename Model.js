function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function clip(s, n) {
  s = String(s == null ? "" : s)
  return s.length > n ? s.substring(0, n) : s
}

function safeText(s, n) {
  s = clip(s, n)
  return s.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "")
  if (lines.length > 8192) lines = lines.substring(0, 8192)
  lines = lines.split("\n")
  var count = 0
  for (var i = 0; i < lines.length && count < 32; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var key = safeText(lines[i].substring(0, idx).trim(), 32)
    if (!key) continue
    next[key] = safeText(lines[i].substring(idx + 1).trim(), 96)
    count++
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var blob = String(raw || "")
  if (blob.length > 4096) blob = blob.substring(0, 4096)
  var lines = blob.split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length && list.length < 8; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length < 2) continue
    var name = safeText(parts[0], 32)
    if (!/^[a-z0-9_-]+$/.test(name)) continue
    list.push(name)
    if (parts[1] === "1") active = name
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

function batteryStateLabel(device, states) {
  var d = device || {}
  var s = states || {}
  if (d.state === s.FullyCharged) return "Full"
  if (d.state === s.Charging) return "Charging"
  if (d.state === s.Discharging) return "Discharging"
  if (d.state === s.PendingCharge) return "Pending charge"
  if (d.state === s.PendingDischarge) return "Pending discharge"
  if (d.state === s.Empty) return "Empty"
  return "Unknown"
}

function rateLabel(device) {
  var d = device || {}
  var rate = Math.abs(Number(d.changeRate || 0))
  if (rate < 0.05) return "0W"
  return rate.toFixed(1).replace(/\.0$/, "") + "W"
}

// Signed per-battery rate: "+" drains the battery, "-" charges it.
function rateSigned(device, states) {
  var d = device || {}
  var s = states || {}
  var v = Math.abs(Number(d.changeRate || 0))
  if (v < 0.05) return "0W"
  // Matching macOS: charging shows "-" (energy going back in), discharge
  // shows the plain number — the direction is already stated by the state.
  var sign = d.state === s.Charging ? "-" : "" 
  return sign + v.toFixed(1).replace(/\.0$/, "") + "W"
}

function formatTime(seconds) {
  if (!(seconds > 0)) return "-"
  var hours = seconds / 3600
  var h = Math.floor(hours)
  var m = Math.round((hours - h) * 60)
  if (m === 60) {
    h += 1
    m = 0
  }
  return m > 0 ? h + "h " + m + "m" : h + "h"
}

// Charge-control threshold range across batteries, e.g. "75-80%" or "80%".

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    clip: clip,
    safeText: safeText,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    batteryStateLabel: batteryStateLabel,
    rateLabel: rateLabel,
    rateSigned: rateSigned,
    formatTime: formatTime
  }
}
