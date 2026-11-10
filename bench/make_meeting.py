#!/usr/bin/env python3
"""Synthesizes a test meeting with macOS voices: a "me" track (microphone) and a "them" track (system audio).

usage: bench/make_meeting.py OUTDIR
Writes OUTDIR/me.wav, OUTDIR/them.wav, OUTDIR/mix.wav and OUTDIR/script.txt (the reference dialogue).
The dialogue mixes German and English and contains names, decisions and action items, so it exercises
diarization, language switching, vocabulary and the summary prompt. Synthetic speech is cleaner than a
real call, so treat results as a pipeline check, not a quality benchmark.
"""
import array
import os
import subprocess
import sys
import tempfile
import wave

RATE = 16000
# Same timbre in both languages, so diarization sees one person per speaker; English lines use the
# English variant so they are pronounced correctly.
VOICES = {
    "Me": {"de": "Eddy (German (Germany))", "en": "Eddy (English (UK))"},
    "Anna": {"de": "Flo (German (Germany))", "en": "Flo (English (UK))"},
    "Flo": {"de": "Grandpa (German (Germany))", "en": "Grandpa (English (UK))"},
    "Daniel": {"de": "Daniel (English (UK))", "en": "Daniel (English (UK))"},
}
GERMAN_MARKERS = set("ä ö ü ß".split()) | {"ich", "wir", "das", "und", "die", "der", "ist", "ja", "gut", "eine"}


def language(text: str) -> str:
    words = set(text.lower().replace(",", " ").replace(".", " ").replace("?", " ").split())
    return "de" if words & GERMAN_MARKERS or any(c in text for c in "äöüß") else "en"
SCRIPT = [
    ("Me", "Hallo zusammen, schön dass ihr alle da seid. Heute wollen wir über den Launch der neuen Evaluierungsplattform sprechen."),
    ("Anna", "Hi! Ja, ich habe die Zahlen von letzter Woche mitgebracht. Wir haben jetzt zweiundvierzig aktive Kunden auf der Beta."),
    ("Flo", "Das ist super. Allerdings hatten wir am Dienstag einen Ausfall vom Backend, ungefähr zwei Stunden lang."),
    ("Me", "Was war die Ursache für den Ausfall?"),
    ("Flo", "Die Datenbank-Migration ist hängen geblieben. Ich habe das gefixt, aber wir brauchen besseres Monitoring."),
    ("Daniel", "Sorry for joining late. Can we switch to English for a moment? I only caught the last part about the outage."),
    ("Me", "Sure, no problem. Flo said the database migration got stuck on Tuesday and the backend was down for about two hours."),
    ("Daniel", "Okay, that is important for the enterprise customers. We promised them ninety nine point nine percent uptime in the contract."),
    ("Anna", "Right. I think we should set up proper alerting before the launch. Otherwise we will not notice problems in time."),
    ("Me", "Agreed. Let's decide that the launch only happens once monitoring and alerting are in place."),
    ("Daniel", "Fine with me. When is the launch planned at the moment?"),
    ("Anna", "Currently on the twenty fourth of November. That gives us two more weeks."),
    ("Me", "Gut, dann machen wir wieder auf Deutsch weiter. Flo, kannst du das Monitoring bis nächsten Freitag aufsetzen?"),
    ("Flo", "Ja, das schaffe ich. Ich nehme Grafana und richte Alerts für die Datenbank und die API ein."),
    ("Anna", "Ich kümmere mich um die Kommunikation an die Beta-Kunden und schreibe einen Blogpost für den Launch."),
    ("Me", "Sehr gut. Und ich spreche mit dem Vertrieb über die Preise für das Enterprise-Paket."),
    ("Daniel", "One more thing. The customer from Munich asked whether we support single sign on. Do we have an answer?"),
    ("Flo", "Not yet. That would take us about three weeks, so it will not make it into the launch."),
    ("Me", "Then let's put single sign on on the roadmap for January and tell the customer honestly."),
    ("Daniel", "Okay, I will write to them tomorrow."),
    ("Anna", "Eine offene Frage habe ich noch: Wer übernimmt den Support in der Launch-Woche?"),
    ("Me", "Das klären wir nächste Woche im Team-Meeting. Danke euch allen, bis dann!"),
]


def render(text: str, voice: str) -> array.array:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "line.wav")
        subprocess.run(
            ["say", "-v", voice, "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text], check=True
        )
        with wave.open(path) as w:
            return array.array("h", w.readframes(w.getnframes()))


def write(path: str, samples: array.array) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())


def main(outdir: str) -> None:
    os.makedirs(outdir, exist_ok=True)
    me, them = array.array("h"), array.array("h")
    gap = array.array("h", [0] * int(RATE * 0.6))
    lines = []
    for speaker, text in SCRIPT:
        audio = render(text, VOICES[speaker][language(text)])
        silence = array.array("h", [0] * len(audio))
        start = len(me) / RATE
        if speaker == "Me":
            me += audio
            them += silence
        else:
            them += audio
            me += silence
        me += gap
        them += gap
        lines.append(f"[{start:6.1f}] {speaker}: {text}")
    mix = array.array("h", (max(-32768, min(32767, a + b)) for a, b in zip(me, them)))
    write(os.path.join(outdir, "me.wav"), me)
    write(os.path.join(outdir, "them.wav"), them)
    write(os.path.join(outdir, "mix.wav"), mix)
    with open(os.path.join(outdir, "script.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(me) / RATE:.0f}s written to {outdir}")


if __name__ == "__main__":
    main(sys.argv[1])
