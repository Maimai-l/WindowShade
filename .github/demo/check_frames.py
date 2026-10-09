#!/usr/bin/env python3
"""Check a demo recording frame by frame (docs/testing.md section 6).

Usage: check_frames.py VIDEO EVENTS_JSON APP_LOG

VIDEO        recording written by DemoDriver (only changed frames are stored)
EVENTS_JSON  written by DemoDriver: window frame, screen size, scale and the
             times (seconds from the start of the recording) of the fold and
             unfold double-clicks
APP_LOG      WindowShade's log for the same run

Exits 1 when any check fails. Needs only python3 and ffmpeg/ffprobe.
"""

import colorsys
import json
import os
import re
import subprocess
import sys

# Mean absolute difference (0-255) above which two title-bar crops are
# treated as different pictures. Calibrated on recordings from 2026-10-08:
# frames of a correct fold or unfold differ from the picture before or after
# by at most 7.2; a blank frame differed by 246 and a title bar covered by
# another window by 55.
SAME_PICTURE = 12
# The window body must change at least this much when the window rolls up.
ROLLED_UP = 20
# Recording-indicator pixels in the traffic-light area that count as a hit.
INDICATOR_PIXELS = 40
# Seconds after a double-click by which the fold or unfold must be finished.
# On the CI virtual machine one window capture sometimes takes 1.1-1.7 s, so a
# fold can take up to about 2.3 s there; on a real Mac the same capture took
# 45-182 ms over 12 folds (2026-10-08). This check judges blank and covered
# frames, not latency, so it allows for the slow machine. The driver waits
# 2.0 s after the fold double-click before moving the pointer, and 2.5 s after
# the unfold double-click before it stops recording.
SETTLE = 2.4


def frame_times(video):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
         "frame=pts_time", "-of", "csv=p=0", video],
        capture_output=True, text=True, check=True).stdout.split()
    return [float(t.split(",")[0]) for t in out if t.split(",")[0]]


def crops(video, rect, scale, shrink):
    """Every stored frame's crop of rect (points), as rgb24 bytes."""
    x, y, w, h = (int(round(v * scale)) for v in rect)
    ow, oh = max(1, w // shrink), max(1, h // shrink)
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
         "-vf", f"crop={w}:{h}:{x}:{y},scale={ow}:{oh}",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True).stdout
    size = ow * oh * 3
    return [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]


def difference(a, b):
    return sum(abs(p - q) for p, q in zip(a, b)) / max(1, len(a))


def indicator_pixels(crop):
    count = 0
    for i in range(0, len(crop), 3):
        r, g, b = crop[i], crop[i + 1], crop[i + 2]
        if b >= 115 and b >= r and b >= g:
            hue, sat, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if sat >= 0.35 and 225 <= hue * 360 <= 270:
                count += 1
    return count


def last_before(times, t):
    idx = [i for i, v in enumerate(times) if v <= t]
    return idx[-1] if idx else 0


def first_after(times, t):
    idx = [i for i, v in enumerate(times) if v >= t]
    return idx[0] if idx else len(times) - 1


def check_transition(name, times, band, body, at, expect_body_change):
    """Section 6.1: every frame's title bar matches the picture before or after."""
    failures = []
    before = last_before(times, at - 0.25)
    after = first_after(times, at + SETTLE)
    if expect_body_change and difference(body[before], body[after]) < ROLLED_UP:
        failures.append(f"{name}: the window body did not change within {SETTLE}s of the double-click")
    for i, t in enumerate(times):
        if not (at - 0.1 <= t <= at + SETTLE):
            continue
        d_before = difference(band[i], band[before])
        d_after = difference(band[i], band[after])
        if min(d_before, d_after) > SAME_PICTURE:
            failures.append(f"{name}: title bar at {t:.3f}s matches neither the picture before "
                            f"nor after (difference {d_before:.0f} / {d_after:.0f}): blank or covered")
    return failures


# Section 6.5: dragging the strip. The pointer moves 240 points per second.
# The strip may trail the pointer by at most this many points (about 80 ms at
# that speed, five frames at 60 frames per second).
DRAG_LAG = 20
# A stall is this many frames in a row where the pointer moved more than two
# points and the strip moved less than half a point.
DRAG_STALL_FRAMES = 2
# The strip may not move against the pointer by more than this.
DRAG_BACKWARD = 1.5


def profile(crop, width, height):
    """Mean brightness of each column of an rgb24 crop."""
    columns = [0.0] * width
    for row in range(height):
        base = row * width * 3
        for col in range(width):
            i = base + col * 3
            columns[col] += crop[i] + crop[i + 1] + crop[i + 2]
    return [c / (3 * height) for c in columns]


def best_offset(template, signal, low, high):
    """Offset (in columns) where template matches signal best, searched in [low, high]."""
    def cost(offset):
        total, n = 0.0, 0
        for i, v in enumerate(template):
            j = i + offset
            if 0 <= j < len(signal):
                total += abs(v - signal[j])
                n += 1
        return total / n if n > len(template) // 2 else float("inf")
    coarse = min(range(low, high + 1, 4), key=cost)
    return min(range(max(low, coarse - 4), min(high, coarse + 4) + 1), key=cost)


def check_drag(video, events, times, scale, screen_w):
    """Section 6.5: while the strip is dragged it follows the pointer without lag, stalls or jumping back."""
    drag = events.get("drag")
    if not drag or not drag.get("path"):
        return [], "no drag recorded"
    window = events["window"]
    path = drag["path"]
    grab_x = drag["grab"][0]
    shrink = 2
    left = max(0, window["x"] - 40)
    right = min(screen_w, window["x"] + window["w"] + 300)
    rect = (left, window["y"] + 3, right - left, 20)
    crops_wide = crops(video, rect, scale, shrink)
    width = max(1, int(round(rect[2] * scale)) // shrink)
    height = max(1, int(round(rect[3] * scale)) // shrink)
    count = min(len(times), len(crops_wide))
    start, end = path[0][0], path[-1][0]
    before = last_before(times[:count], start - 0.05)
    # Template: the strip itself (right of the traffic lights) in the frame before the drag.
    t_left = int(round((window["x"] + 80 - left) * scale)) // shrink
    t_right = int(round((window["x"] + window["w"] - 10 - left) * scale)) // shrink
    template = profile(crops_wide[before], width, height)[t_left:t_right]
    points_per_column = shrink / scale

    def pointer_dx(t):
        if t <= path[0][0]:
            return path[0][1] - grab_x
        for (t0, x0, _), (t1, x1, _) in zip(path, path[1:]):
            if t0 <= t <= t1:
                return (x0 + (x1 - x0) * ((t - t0) / max(1e-6, t1 - t0))) - grab_x
        return path[-1][1] - grab_x

    samples = []
    for i in range(count):
        if not (start <= times[i] <= end):
            continue
        signal = profile(crops_wide[i], width, height)
        offset = best_offset(template, signal, t_left - 20, t_left + int(260 / points_per_column))
        samples.append((times[i], (offset - t_left) * points_per_column, pointer_dx(times[i])))
    if len(samples) < 10:
        return [f"drag: only {len(samples)} frames during the drag"], "too few frames"

    lags = [abs(p - s) for _, s, p in samples]
    stalls, run, backward = 0, 0, 0
    for (_, s0, p0), (_, s1, p1) in zip(samples, samples[1:]):
        ds, dp = s1 - s0, p1 - p0
        if abs(dp) > 2 and abs(ds) < 0.5:
            run += 1
            if run == DRAG_STALL_FRAMES:
                stalls += 1
        else:
            run = 0
        if abs(dp) > 2 and ds * dp < 0 and abs(ds) > DRAG_BACKWARD:
            backward += 1
    summary = (f"drag: {len(samples)} frames, largest lag {max(lags):.1f} pt, "
               f"{stalls} stalls, {backward} backward jumps")
    failures = []
    if max(lags) > DRAG_LAG:
        failures.append(f"drag: the strip trailed the pointer by {max(lags):.1f} pt (limit {DRAG_LAG})")
    if stalls:
        failures.append(f"drag: the strip stopped while the pointer moved, {stalls} times")
    if backward:
        failures.append(f"drag: the strip jumped back against the pointer {backward} times")
    return failures, summary


def check_state_machine(log_text):
    """The fold state machine never sees an illegal transition (docs/testing.md section 5)."""
    return [f"state: {line.strip()}" for line in log_text.splitlines() if "illegal transition" in line]


def check_geometry(log_text, window):
    """Section 6.3: the window comes back where and how big it was."""
    failures = []
    pattern = re.compile(r"geometry: restore immediate target=\((-?\d+),(-?\d+) (\d+)x(\d+)\)"
                         r".*?actual=\((-?\d+),(-?\d+) (\d+)x(\d+)\)")
    expected = (window["x"], window["y"], window["w"], window["h"])
    found = False
    for m in pattern.finditer(log_text):
        target = tuple(int(v) for v in m.groups()[:4])
        actual = tuple(int(v) for v in m.groups()[4:])
        if target[2:] != expected[2:]:
            continue  # another app's window in the same log
        found = True
        if target != expected:
            failures.append(f"geometry: unfold target {target} differs from the window before folding {expected}")
        if actual != target:
            failures.append(f"geometry: window came back at {actual}, expected {target}")
    if not found:
        failures.append(f"geometry: no unfold of a {expected[2]}x{expected[3]} window in the log")
    return failures


def main():
    video, events_path, log_path = sys.argv[1:4]
    try:
        return check(video, events_path, log_path)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b"")
        detail = detail.decode(errors="replace") if isinstance(detail, bytes) else detail
        print(f"FAIL {video}: {error.cmd[0]} could not read the recording: {detail.strip()}")
        return 1


def check(video, events_path, log_path):
    events = json.load(open(events_path))
    window, scale = events["window"], events["scale"]
    screen_w = events["screen"]["w"]
    times = frame_times(video)
    if len(times) < 10:
        print(f"FAIL {video}: only {len(times)} frames recorded")
        return 1

    top, left = window["y"], window["x"]
    right = min(left + window["w"], screen_w) - 10
    # Title bar band: right of the traffic lights (their colour changes with focus).
    band_rect = (left + 80, top + 3, right - left - 80, 20)
    body_rect = (left + 40, top + 70, min(300, right - left - 40), 60)
    lights_rect = (left, max(0, top - 10), 180, 50)

    band = crops(video, band_rect, scale, 2)
    body = crops(video, body_rect, scale, 2)
    lights = crops(video, lights_rect, scale, 1)
    count = min(len(times), len(band), len(body), len(lights))
    times = times[:count]

    failures = []
    failures += check_transition("fold", times, band, body, events["fold"], True)
    failures += check_transition("unfold", times, band, body, events["unfold"], False)
    for i, t in enumerate(times):
        pixels = indicator_pixels(lights[i])
        if pixels > INDICATOR_PIXELS:
            failures.append(f"indicator: recording indicator at {t:.3f}s ({pixels} pixels)")
    drag_failures, drag_summary = check_drag(video, events, times, scale, screen_w)
    # Frame timing on the CI virtual machine is not steady: there the numbers are only reported.
    if os.environ.get("WINDOWSHADE_LOCAL") == "1":
        failures += drag_failures
    else:
        for line in drag_failures:
            print(f"INFO {video}: {line} (not judged on CI)")
    print(f"INFO {video}: {drag_summary}")
    log_text = open(log_path, errors="replace").read()
    failures += check_geometry(log_text, window)
    failures += check_state_machine(log_text)

    for line in failures:
        print(f"FAIL {video}: {line}")
    if not failures:
        print(f"PASS {video}: {count} frames; no blank or covered title bar, "
              f"no recording indicator, window restored to {window}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
