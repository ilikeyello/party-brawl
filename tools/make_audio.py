#!/usr/bin/env python3
"""Generates all of Party Brawl's music and sound effects from scratch (no samples).
Run:  python3 tools/make_audio.py   ->  writes audio/*.ogg
Everything here is original and free to use."""
import os, subprocess, tempfile
import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 32000
OUT = os.path.join(os.path.dirname(__file__), "..", "audio")
rng = np.random.default_rng(7)


# ------------------------------------------------------------------ basics
def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def note_hz(n):
    """MIDI note -> Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


def env_adsr(n, a=0.005, d=0.08, s=0.6, r=0.08):
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(n - a_n - d_n - r_n, 0)
    e = np.concatenate([
        np.linspace(0, 1, max(a_n, 1), endpoint=False),
        np.linspace(1, s, max(d_n, 1), endpoint=False),
        np.full(s_n, s),
        np.linspace(s, 0, max(r_n, 1)),
    ])
    if len(e) < n:
        e = np.pad(e, (0, n - len(e)))
    return e[:n]


def env_exp(n, decay):
    return np.exp(-np.arange(n) / SR / decay)


def osc(kind, freq, dur, phase=0.0):
    """freq can be a number or an array (sweeps)."""
    n = int(dur * SR)
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,)) if np.ndim(freq) else np.full(n, float(freq))
    ph = 2 * np.pi * np.cumsum(f) / SR + phase
    if kind == "sine":
        return np.sin(ph)
    if kind == "square":
        return np.tanh(np.sin(ph) * 6) * 0.8
    if kind == "pulse":
        return np.tanh((np.sin(ph) + 0.4) * 5) * 0.7
    if kind == "saw":
        return 2 * ((ph / (2 * np.pi)) % 1.0) - 1
    if kind == "tri":
        return 2 * np.abs(2 * ((ph / (2 * np.pi)) % 1.0) - 1) - 1
    raise ValueError(kind)


def noise(dur):
    return rng.uniform(-1, 1, int(dur * SR))


def lp(x, cutoff, order=2):
    b, a = signal.butter(order, min(cutoff / (SR / 2), 0.99), "low")
    return signal.lfilter(b, a, x)


def hp(x, cutoff, order=2):
    b, a = signal.butter(order, min(cutoff / (SR / 2), 0.99), "high")
    return signal.lfilter(b, a, x)


def bp(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (SR / 2), min(hi / (SR / 2), 0.99)], "band")
    return signal.lfilter(b, a, x)


def mix_at(buf, x, start_s, gain=1.0):
    i = int(start_s * SR)
    if i >= len(buf):
        return
    j = min(len(buf), i + len(x))
    buf[i:j] += x[: j - i] * gain


def echo(x, delay, fb=0.35, mix=0.3, taps=4):
    out = x.copy()
    d = int(delay * SR)
    g = mix
    for k in range(1, taps + 1):
        if d * k >= len(x):
            break
        out[d * k:] += x[: len(x) - d * k] * g
        g *= fb
    return out


def normalize(x, peak=0.89):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def soft_clip(x, drive=1.2):
    return np.tanh(x * drive) / np.tanh(drive)


def save(name, x, loop=False):
    os.makedirs(OUT, exist_ok=True)
    x = np.clip(x, -1, 1)
    # tiny fades so nothing clicks (loops are left untouched at the seam)
    if not loop:
        f = min(64, len(x) // 4)
        x[:f] *= np.linspace(0, 1, f)
        x[-f:] *= np.linspace(1, 0, f)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wavfile.write(tmp.name, SR, (x * 32767).astype(np.int16))
        q = "4" if loop else "5"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-c:a", "libvorbis", "-q:a", q,
                        os.path.join(OUT, name + ".ogg")], check=True)
        os.unlink(tmp.name)
    print(f"  {name}.ogg  {len(x)/SR:.2f}s")


# ------------------------------------------------------------------ drum kit
def kick(dur=0.35, punch=1.0):
    t = t_axis(dur)
    f = 45 + 110 * np.exp(-t / 0.035)
    body = osc("sine", f, dur) * env_exp(len(t), 0.14)
    click = hp(noise(dur), 2000) * env_exp(len(t), 0.004) * 0.3
    return (body + click) * punch


def snare(dur=0.22):
    t = t_axis(dur)
    tone = osc("tri", 190 * (1 + 0.3 * np.exp(-t / 0.02)), dur) * env_exp(len(t), 0.05) * 0.5
    nz = bp(noise(dur), 1200, 8000) * env_exp(len(t), 0.07)
    return tone + nz * 0.9


def clap(dur=0.25):
    n = noise(dur)
    e = np.zeros(len(n))
    for off in (0.0, 0.011, 0.022):
        e += np.roll(env_exp(len(n), 0.012), int(off * SR))
    e += np.roll(env_exp(len(n), 0.09), int(0.03 * SR)) * 0.6
    return bp(n, 900, 5000) * e * 0.9


def hat(dur=0.06, open_=False):
    d = 0.25 if open_ else dur
    return hp(noise(d), 7000) * env_exp(int(d * SR), 0.09 if open_ else 0.018) * 0.45


# ------------------------------------------------------------------ instruments
def pluck(midi, dur, kind="square", cutoff=3500, decay=0.18, vol=0.5):
    x = osc(kind, note_hz(midi), dur)
    x = lp(x, cutoff)
    return x * env_exp(len(x), decay) * vol


def lead(midi, dur, kind="pulse", vib=0.0, vol=0.45, rel=0.05):
    t = t_axis(dur)
    f = note_hz(midi) * (1 + vib * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.08) * 6, 0, 1))
    x = lp(osc(kind, f, dur), 4500)
    return x * env_adsr(len(t), 0.01, 0.06, 0.75, rel) * vol


def bass(midi, dur, kind="saw", vol=0.55):
    x = osc(kind, note_hz(midi), dur) * 0.7 + osc("sine", note_hz(midi - 12), dur) * 0.5
    x = lp(x, 900)
    return x * env_adsr(len(x), 0.004, 0.08, 0.7, 0.04) * vol


def pad(midis, dur, vol=0.16):
    x = sum(osc("saw", note_hz(m) * (1 + d), dur) for m in midis for d in (-0.003, 0.003))
    x = lp(x, 1800)
    return x * env_adsr(len(x), 0.08, 0.2, 0.8, 0.15) * vol / len(midis)


def bell(midi, dur, vol=0.35):
    t = t_axis(dur)
    f = note_hz(midi)
    mod = np.sin(2 * np.pi * f * 3.5 * t) * 2.0 * np.exp(-t / 0.3)
    x = np.sin(2 * np.pi * f * t + mod)
    return x * env_exp(len(t), 0.35) * vol


# ------------------------------------------------------------------ tracker
class Song:
    def __init__(self, bpm, bars, steps_per_bar=16):
        self.bpm = bpm
        self.step = 60.0 / bpm / 4  # 16th notes
        self.bars = bars
        self.spb = steps_per_bar
        self.length = self.step * steps_per_bar * bars
        self.tail = 1.5
        self.buf = np.zeros(int((self.length + self.tail) * SR))

    def at(self, bar, step):
        return (bar * self.spb + step) * self.step

    def add(self, x, bar, step, gain=1.0):
        mix_at(self.buf, x, self.at(bar, step), gain)

    def render(self, master=0.85):
        out = self.buf.copy()
        n = int(self.length * SR)
        t = len(out) - n
        out[:t] += out[n:]  # wrap the tail so the loop is seamless
        out = out[:n]
        out = soft_clip(out * 1.1, 1.3)
        return normalize(out, master)


def drum_pattern(song, bar, kick_steps, snare_steps, hat_steps, open_steps=(), clap_steps=(), kgain=1.0):
    for s in kick_steps:
        song.add(kick(), bar, s, 0.95 * kgain)
    for s in snare_steps:
        song.add(snare(), bar, s, 0.55)
    for s in clap_steps:
        song.add(clap(), bar, s, 0.45)
    for s in hat_steps:
        song.add(hat(), bar, s, 0.5 if s % 4 == 2 else 0.32)
    for s in open_steps:
        song.add(hat(open_=True), bar, s, 0.28)


def chord_notes(root, kind="maj"):
    return [root, root + (4 if kind == "maj" else 3), root + 7]


# ------------------------------------------------------------------ songs
def song_lobby():
    """Funky, friendly party groove. C major, 112 BPM, 16 bars."""
    s = Song(112, 16)
    prog = [(48, "maj"), (45, "min"), (41, "maj"), (43, "maj")]  # C Am F G
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 6, 10] if bar % 2 == 0 else [0, 7, 10, 14], [4, 12], range(0, 16, 2), [14], kgain=0.9)
        # bass: syncopated
        for st, off, ln in [(0, 0, 3), (3, 12, 1), (6, 0, 2), (10, 7, 2), (14, 12, 2)]:
            s.add(bass(root + off - 12, s.step * ln), bar, st)
        # chord stabs on the off-beats
        ch = [n + 12 for n in chord_notes(root + 12, kind)]
        for st in (2, 6, 10, 14):
            for n in ch:
                s.add(pluck(n, s.step * 1.5, "square", 2600, 0.09, 0.14), bar, st)
        if bar >= 4:
            s.add(pad([n + 12 for n in chord_notes(root + 12, kind)], s.step * 16), bar, 0, 0.8)
    # bell melody (bars 4-15)
    mel = [
        [(0, 72, 2), (2, 76, 2), (4, 79, 4), (10, 76, 2), (12, 74, 4)],
        [(0, 72, 2), (2, 69, 2), (4, 72, 6), (12, 76, 4)],
        [(0, 77, 2), (2, 76, 2), (4, 74, 2), (6, 72, 4), (12, 69, 4)],
        [(0, 71, 2), (2, 72, 2), (4, 74, 4), (8, 79, 6)],
    ]
    for bar in range(4, 16):
        for st, n, ln in mel[bar % 4]:
            s.add(bell(n, s.step * ln + 0.3), bar, st, 0.9)
    return s.render(0.72)


def song_sumo():
    """Tense but bouncy. A minor, 124 BPM, 16 bars. Taiko-ish toms + plucky riff."""
    s = Song(124, 16)
    prog = [(45, "min"), (41, "maj"), (43, "maj"), (40, "min")]  # Am F G Em
    riff = [0, 12, 7, 12, 0, 12, 10, 12, 0, 12, 7, 12, 3, 5, 7, 10]
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 8, 11] if bar % 4 != 3 else [0, 4, 8, 10, 12, 14], [4, 12], range(0, 16, 2), kgain=1.0)
        if bar % 2 == 1:
            for st in (13, 14, 15):  # tom fill
                t = t_axis(0.3)
                tom = osc("sine", 110 * (1 + 0.5 * np.exp(-t / 0.04)) * (1.25 - 0.1 * (st - 13)), 0.3) * env_exp(len(t), 0.12)
                s.add(tom, bar, st, 0.45)
        for st in range(0, 16, 2):
            s.add(bass(root - 12 + (12 if st in (6, 14) else 0), s.step * 1.8, "square", 0.5), bar, st)
        for i, off in enumerate(riff):
            s.add(pluck(root + 24 + off, s.step * 1.2, "pulse", 3000, 0.07, 0.12), bar, i)
        if bar >= 8:
            s.add(pad([n + 12 for n in chord_notes(root + 12, kind)], s.step * 16, 0.13), bar, 0)
    hook = [[(0, 69, 3), (4, 72, 3), (8, 76, 4), (12, 74, 4)],
            [(0, 72, 3), (4, 69, 3), (8, 65, 6)],
            [(0, 67, 3), (4, 71, 3), (8, 74, 4), (12, 72, 4)],
            [(0, 71, 6), (8, 64, 6)]]
    for bar in range(8, 16):
        for st, n, ln in hook[bar % 4]:
            s.add(lead(n, s.step * ln, "pulse", 0.006, 0.22), bar, st)
    return s.render(0.72)


def song_bomb():
    """Frantic and fun, ticking hats. D minor, 148 BPM, 16 bars."""
    s = Song(148, 16)
    prog = [(50, "min"), (46, "maj"), (48, "maj"), (45, "maj")]  # Dm Bb C A
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 4, 8, 12], [4, 12], range(16), [6, 14], kgain=0.85)
        for st in range(0, 16, 1):
            if st % 2 == 0:
                s.add(bass(root - 12 + (7 if st in (6, 14) else 0), s.step * 0.9, "saw", 0.45), bar, st)
        # "clock" ticks
        for st in (0, 4, 8, 12):
            tk = hp(osc("square", 2400, 0.03), 1500) * env_exp(int(0.03 * SR), 0.006) * 0.25
            s.add(tk, bar, st + 2)
        arp = chord_notes(root + 24, kind) + [root + 36]
        for st in range(16):
            s.add(pluck(arp[st % 4], s.step, "square", 4000, 0.05, 0.08), bar, st)
    melody = [[(0, 74, 2), (2, 74, 2), (4, 77, 2), (6, 74, 2), (8, 81, 4), (12, 79, 4)],
              [(0, 77, 2), (2, 74, 2), (4, 70, 4), (8, 74, 6)],
              [(0, 72, 2), (2, 76, 2), (4, 79, 4), (8, 76, 2), (10, 72, 2), (12, 76, 4)],
              [(0, 73, 4), (4, 76, 4), (8, 81, 6)]]
    for bar in range(4, 16):
        for st, n, ln in melody[bar % 4]:
            s.add(lead(n, s.step * ln, "square", 0.004, 0.18), bar, st)
    return s.render(0.72)


def song_paint():
    """Happy and bouncy. F major, 132 BPM, 16 bars. Marimba-ish."""
    s = Song(132, 16)
    prog = [(41, "maj"), (46, "maj"), (38, "min"), (48, "maj")]  # F Bb Dm C
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 8, 10], [], range(0, 16, 2), [6, 14], clap_steps=[4, 12], kgain=0.85)
        for st, off in [(0, 0), (4, 7), (8, 12), (12, 7)]:
            s.add(bass(root - 12 + off, s.step * 3, "tri", 0.7), bar, st)
        ch = chord_notes(root + 24, kind)
        pattern = [ch[0], ch[1], ch[2], ch[1], ch[0] + 12, ch[2], ch[1], ch[2]]
        for i, n in enumerate(pattern):
            t = t_axis(0.25)
            mar = (np.sin(2 * np.pi * note_hz(n) * t) + 0.3 * np.sin(2 * np.pi * note_hz(n) * 4 * t) * np.exp(-t / 0.02)) * env_exp(len(t), 0.09)
            s.add(mar, bar, i * 2, 0.22)
    melody = [[(0, 77, 2), (2, 79, 2), (4, 81, 4), (8, 84, 2), (10, 81, 2), (12, 79, 4)],
              [(0, 82, 2), (2, 81, 2), (4, 79, 2), (6, 77, 2), (8, 74, 6)],
              [(0, 74, 2), (2, 77, 2), (4, 81, 4), (8, 79, 2), (10, 77, 2), (12, 74, 4)],
              [(0, 72, 4), (4, 76, 4), (8, 79, 6)]]
    for bar in range(4, 16):
        for st, n, ln in melody[bar % 4]:
            s.add(lead(n, s.step * ln, "tri", 0.008, 0.3), bar, st)
    return s.render(0.72)


def song_floor():
    """Urgent, rumbly. E minor, 136 BPM, 16 bars. Low toms + driving bass."""
    s = Song(136, 16)
    prog = [(40, "min"), (36, "maj"), (38, "maj"), (35, "maj")]  # Em C D B
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 3, 8, 11], [4, 12], range(0, 16, 2), [14], kgain=1.0)
        for st in (6, 14):
            t = t_axis(0.35)
            tom = osc("sine", 80 * (1 + 0.6 * np.exp(-t / 0.05)), 0.35) * env_exp(len(t), 0.14)
            s.add(tom, bar, st, 0.5)
        for st in range(0, 16, 2):
            s.add(bass(root + (7 if st in (4, 12) else 0), s.step * 1.6, "saw", 0.5), bar, st)
        arp = chord_notes(root + 24, kind)
        for st in range(0, 16, 2):
            s.add(pluck(arp[(st // 2) % 3] + (12 if st >= 8 else 0), s.step * 1.4, "pulse", 2800, 0.08, 0.1), bar, st + 1)
    hook = [[(0, 76, 2), (2, 79, 2), (4, 78, 4), (8, 76, 2), (10, 74, 2), (12, 71, 4)],
            [(0, 72, 4), (4, 76, 4), (8, 79, 6)],
            [(0, 74, 2), (2, 78, 2), (4, 81, 4), (8, 78, 4), (12, 74, 4)],
            [(0, 75, 6), (8, 71, 6)]]
    for bar in range(4, 16):
        for st, n, ln in hook[bar % 4]:
            s.add(lead(n, s.step * ln, "square", 0.005, 0.18), bar, st)
    return s.render(0.72)


def song_trails():
    """Synthwave chase. A minor, 128 BPM, 16 bars. Pulsing 8th bass + arps."""
    s = Song(128, 16)
    prog = [(45, "min"), (41, "maj"), (48, "maj"), (43, "maj")]  # Am F C G
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 4, 8, 12], [4, 12], range(2, 16, 4), [], clap_steps=[12] if bar % 2 else [], kgain=0.9)
        for st in range(0, 16, 2):
            s.add(lp(bass(root - 12, s.step * 1.7, "saw", 0.55), 900), bar, st)
        arp = chord_notes(root + 24, kind) + [root + 36]
        for st in range(16):
            s.add(pluck(arp[[0, 1, 2, 3, 2, 1][st % 6]], s.step * 1.1, "saw", 3200, 0.06, 0.09), bar, st)
        s.add(pad([n + 12 for n in chord_notes(root + 12, kind)], s.step * 16, 0.12), bar, 0)
    mel = [[(0, 76, 6), (6, 74, 2), (8, 72, 4), (12, 69, 4)],
           [(0, 72, 6), (6, 74, 2), (8, 77, 8)],
           [(0, 79, 4), (4, 76, 4), (8, 72, 4), (12, 76, 4)],
           [(0, 74, 8), (8, 71, 8)]]
    for bar in range(8, 16):
        for st, n, ln in mel[bar % 4]:
            s.add(lead(n, s.step * ln, "saw", 0.008, 0.15), bar, st)
    return s.render(0.72)


def song_balloon():
    """Silly carnival waltz-ish bounce. G major, 116 BPM, 16 bars. Oom-pah + bells."""
    s = Song(116, 16)
    prog = [(43, "maj"), (48, "maj"), (50, "maj"), (43, "maj")]  # G C D G
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 8], [], [4, 12], [], clap_steps=[4, 12], kgain=0.7)
        for st, off in [(0, 0), (8, 7)]:
            s.add(bass(root - 12 + off, s.step * 3, "tri", 0.7), bar, st)
        ch = chord_notes(root + 12, kind)
        for st in (4, 6, 12, 14):
            for n in ch:
                s.add(pluck(n + 12, s.step * 1.2, "square", 2400, 0.07, 0.1), bar, st)
    mel = [[(0, 79, 2), (2, 81, 2), (4, 83, 4), (8, 86, 4), (12, 83, 4)],
           [(0, 84, 2), (2, 83, 2), (4, 81, 4), (8, 79, 8)],
           [(0, 81, 2), (2, 83, 2), (4, 84, 4), (8, 81, 2), (10, 78, 2), (12, 74, 4)],
           [(0, 79, 4), (4, 83, 4), (8, 79, 6)]]
    for bar in range(2, 16):
        for st, n, ln in mel[bar % 4]:
            s.add(bell(n, s.step * ln + 0.25, 0.32), bar, st, 0.9)
    return s.render(0.72)


def song_heist():
    """Sneaky spy groove. D minor, 104 BPM, 16 bars. Walking bass + muted stabs."""
    s = Song(104, 16)
    prog = [(38, "min"), (38, "min"), (43, "min"), (45, "maj")]  # Dm Dm Gm A
    walk = [0, 3, 5, 6, 7, 6, 5, 3]
    for bar in range(16):
        root, kind = prog[bar % 4]
        drum_pattern(s, bar, [0, 10], [4, 12], range(0, 16, 2), [6], kgain=0.8)
        for i, off in enumerate(walk):
            s.add(bass(root - 12 + off, s.step * 1.8, "tri", 0.75), bar, i * 2)
        ch = chord_notes(root + 24, kind)
        for st in (3, 11):
            for n in ch:
                s.add(pluck(n, s.step * 0.8, "pulse", 2000, 0.05, 0.12), bar, st)
    mel = [[(0, 74, 3), (4, 77, 1), (5, 76, 1), (6, 74, 2), (8, 69, 6)],
           [(0, 74, 3), (4, 77, 1), (5, 79, 1), (6, 81, 2), (8, 80, 6)],
           [(0, 79, 3), (4, 82, 1), (5, 81, 1), (6, 79, 2), (8, 74, 6)],
           [(0, 76, 4), (4, 73, 4), (8, 69, 6)]]
    for bar in range(4, 16):
        for st, n, ln in mel[bar % 4]:
            s.add(lead(n, s.step * ln, "pulse", 0.006, 0.2), bar, st)
    return s.render(0.72)


def fanfare():
    """Winner jingle (not looped)."""
    s = Song(140, 3)
    notes = [(0, 0, 72, 2), (0, 2, 72, 2), (0, 4, 72, 2), (0, 6, 76, 6), (0, 12, 74, 2), (0, 14, 76, 2),
             (1, 0, 79, 12)]
    for bar, st, n, ln in notes:
        for k in (0, 4, 7):
            s.add(lead(n + k - 12 if k else n, s.step * ln, "pulse", 0.01 if ln > 6 else 0, 0.16), bar, st)
    s.add(kick(), 0, 0)
    s.add(snare(), 0, 6, 0.5)
    for st in range(0, 12, 2):  # snare roll into the big chord
        s.add(snare(0.12), 0, 6 + st // 2 if False else st, 0.0)
    s.add(kick(), 1, 0)
    t = t_axis(1.6)
    cym = hp(noise(1.6), 5000) * env_exp(len(t), 0.5) * 0.35
    s.add(cym, 1, 0)
    for n in (60, 64, 67, 72):
        s.add(pad([n], s.step * 16, 0.5), 1, 0)
    out = s.buf[: int((s.length + 0.8) * SR)]
    return normalize(soft_clip(out, 1.2), 0.8)


# ------------------------------------------------------------------ sound effects
def sfx():
    fx = {}
    # UI
    t = t_axis(0.07)
    fx["click"] = osc("square", np.linspace(900, 1300, len(t)), 0.07) * env_exp(len(t), 0.02) * 0.5
    x = np.zeros(int(0.35 * SR))
    mix_at(x, bell(84, 0.3, 0.5), 0.0)
    mix_at(x, bell(91, 0.3, 0.5), 0.09)
    fx["ready"] = x
    t = t_axis(0.16)
    fx["count"] = lp(osc("square", 660, 0.16), 3000) * env_adsr(len(t), 0.002, 0.03, 0.6, 0.05) * 0.55
    x = np.zeros(int(0.6 * SR))
    for n in (72, 76, 79, 84):
        mix_at(x, lead(n, 0.5, "pulse", 0, 0.25), 0)
    fx["go"] = x
    x = np.zeros(int(0.18 * SR))
    mix_at(x, osc("sine", np.linspace(300, 700, int(0.08 * SR)), 0.08) * env_exp(int(0.08 * SR), 0.03), 0)
    mix_at(x, osc("sine", np.linspace(500, 1000, int(0.08 * SR)), 0.08) * env_exp(int(0.08 * SR), 0.03), 0.07)
    fx["join"] = x * 0.6
    # movement / hits
    t = t_axis(0.28)
    sweep = np.linspace(600, 3500, len(t))
    nz = noise(0.28)
    wh = np.zeros(len(t))
    for i in range(0, len(t), 256):  # crude moving band-pass
        seg = nz[i:i + 256]
        f = sweep[i]
        wh[i:i + len(seg)] = bp(seg, f * 0.6, f * 1.4, 1)
    fx["dash"] = wh * env_adsr(len(t), 0.02, 0.1, 0.5, 0.12) * 1.4
    t = t_axis(0.3)
    thud = osc("sine", 70 + 120 * np.exp(-t / 0.03), 0.3) * env_exp(len(t), 0.09)
    boing = osc("sine", 420 + 160 * np.sin(2 * np.pi * 18 * t), 0.3) * env_exp(len(t), 0.08) * 0.35
    fx["hit"] = thud + boing + hp(noise(0.3), 3000) * env_exp(len(t), 0.006) * 0.4
    t = t_axis(0.9)
    whistle = osc("sine", np.linspace(1100, 180, len(t)) * (1 + 0.02 * np.sin(2 * np.pi * 9 * t)), 0.9) * env_adsr(len(t), 0.01, 0.1, 0.8, 0.2) * 0.5
    sizzle = np.zeros(len(t))
    mix_at(sizzle, bp(noise(0.5), 2000, 7000) * env_exp(int(0.5 * SR), 0.15) * 0.6, 0.55)
    mix_at(sizzle, osc("sine", 90 * np.ones(int(0.3 * SR)), 0.3) * env_exp(int(0.3 * SR), 0.08) * 0.6, 0.55)
    fx["fall"] = whistle + sizzle
    t = t_axis(0.45)
    fx["launch"] = bp(noise(0.45), 500, 4000) * env_adsr(len(t), 0.05, 0.1, 0.6, 0.25) * 0.9 + osc("tri", np.linspace(200, 600, len(t)), 0.45) * env_exp(len(t), 0.15) * 0.3
    x = np.zeros(int(0.25 * SR))
    mix_at(x, hp(noise(0.02), 2000) * 0.6, 0)
    mix_at(x, bell(88, 0.22, 0.4), 0.02)
    fx["lock"] = x
    t = t_axis(1.0)
    rumble = lp(noise(1.0), 140, 3) * env_adsr(len(t), 0.1, 0.2, 0.8, 0.4) * 3.0
    fx["shrink"] = rumble + osc("sine", np.linspace(80, 50, len(t)), 1.0) * env_adsr(len(t), 0.1, 0.2, 0.6, 0.4) * 0.4
    # bomb
    t = t_axis(0.05)
    fx["tick"] = hp(osc("square", 1800, 0.05), 800) * env_exp(len(t), 0.008) * 0.6
    fx["tick_hi"] = hp(osc("square", 2600, 0.06), 800) * env_exp(int(0.06 * SR), 0.012) * 0.8
    t = t_axis(1.3)
    boom = lp(noise(1.3), 900, 2) * env_exp(len(t), 0.35) * 2.2
    sub = osc("sine", 40 + 80 * np.exp(-t / 0.08), 1.3) * env_exp(len(t), 0.3) * 0.9
    crack = hp(noise(1.3), 2500) * env_exp(len(t), 0.03) * 0.6
    fx["explosion"] = soft_clip(boom + sub + crack, 1.5)
    t = t_axis(0.22)
    fx["tag"] = lp(osc("square", np.linspace(1500, 300, len(t)) * (1 + 0.3 * np.sign(np.sin(2 * np.pi * 40 * t))), 0.22), 5000) * env_exp(len(t), 0.07) * 0.5
    x = np.zeros(int(0.4 * SR))
    for i, n in enumerate((72, 76, 79, 84)):
        mix_at(x, pluck(n, 0.2, "square", 5000, 0.08, 0.35), i * 0.055)
    fx["powerup"] = x
    t = t_axis(0.8)
    shimmer = sum(np.sin(2 * np.pi * f * t) * (0.5 + 0.5 * np.sin(2 * np.pi * (7 + k) * t)) for k, f in enumerate((2093, 2637, 3136, 3951)))
    fx["freeze"] = (shimmer * 0.15 + bp(noise(0.8), 5000, 12000) * 0.2) * env_adsr(len(t), 0.01, 0.2, 0.5, 0.4)
    t = t_axis(0.45)
    f = 300 + 1500 * np.sin(np.pi * np.linspace(0, 1, len(t)))
    fx["warp"] = lp(osc("saw", f, 0.45), 3500) * env_adsr(len(t), 0.02, 0.1, 0.7, 0.15) * 0.35
    # paint
    t = t_axis(0.32)
    fx["splat"] = lp(noise(0.32), 1800) * env_exp(len(t), 0.07) * 1.4 + osc("sine", 140 + 200 * np.exp(-t / 0.02), 0.32) * env_exp(len(t), 0.06) * 0.6
    t = t_axis(0.9)
    fx["frenzy"] = lp(osc("square", np.where((t * 6).astype(int) % 2 == 0, 880, 660), 0.9), 3500) * env_adsr(len(t), 0.01, 0.1, 0.8, 0.1) * 0.35
    t = t_axis(0.6)
    fx["eraser"] = lp(osc("saw", 110 + 20 * np.sin(2 * np.pi * 11 * t), 0.6), 1200) * env_adsr(len(t), 0.03, 0.1, 0.8, 0.2) * 0.6
    # results
    fx["ding"] = bell(91, 0.45, 0.5)
    x = np.zeros(int(1.2 * SR))
    for i, n in enumerate((67, 66, 65, 64)):
        mix_at(x, lead(n, 0.32 if i < 3 else 0.7, "saw", 0.012 if i == 3 else 0, 0.3), i * 0.3)
    fx["out"] = lp(x, 2500)
    # new games
    t = t_axis(0.25)
    fx["crack"] = hp(noise(0.25), 1500) * env_exp(len(t), 0.03) * 0.8 + osc("sine", 160 + 90 * np.exp(-t / 0.02), 0.25) * env_exp(len(t), 0.05) * 0.5
    t = t_axis(0.3)
    fx["pop"] = hp(noise(0.3), 800) * env_exp(len(t), 0.025) * 1.6 + osc("sine", 300 * np.exp(-t / 0.05) + 80, 0.3) * env_exp(len(t), 0.04) * 0.7
    t = t_axis(0.22)
    fx["pump"] = bp(noise(0.22), 600, 2400) * env_adsr(len(t), 0.03, 0.08, 0.5, 0.08) * 0.9 + osc("sine", np.linspace(220, 330, len(t)), 0.22) * env_exp(len(t), 0.08) * 0.25
    x = np.zeros(int(0.3 * SR))
    mix_at(x, bell(93, 0.25, 0.4), 0.0)
    mix_at(x, bell(100, 0.2, 0.3), 0.05)
    fx["gem"] = x
    x = np.zeros(int(0.6 * SR))
    for i, n in enumerate((79, 84, 88, 91)):
        mix_at(x, bell(n, 0.35, 0.35), i * 0.06)
    fx["bank"] = x
    return fx


def main():
    print("music:")
    save("music_lobby", song_lobby(), loop=True)
    save("music_sumo", song_sumo(), loop=True)
    save("music_bomb", song_bomb(), loop=True)
    save("music_paint", song_paint(), loop=True)
    save("music_floor", song_floor(), loop=True)
    save("music_trails", song_trails(), loop=True)
    save("music_balloon", song_balloon(), loop=True)
    save("music_heist", song_heist(), loop=True)
    save("fanfare", fanfare())
    print("sfx:")
    for name, x in sfx().items():
        save("sfx_" + name, normalize(x, 0.85))


def main_new():
    """Only the files added in v2.0 (keeps the old ones exactly as they were)."""
    print("music:")
    save("music_floor", song_floor(), loop=True)
    save("music_trails", song_trails(), loop=True)
    save("music_balloon", song_balloon(), loop=True)
    save("music_heist", song_heist(), loop=True)
    print("sfx:")
    for name, x in sfx().items():
        if name in ("crack", "pop", "pump", "gem", "bank"):
            save("sfx_" + name, normalize(x, 0.85))


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "new":
        main_new()
    else:
        main()
