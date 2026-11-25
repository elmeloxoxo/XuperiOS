#!/usr/bin/env python3
"""Genera epg.json (Ahora / Siguiente) a partir de guías XMLTV públicas.

Se ejecuta en GitHub Actions (.github/workflows/epg.yml). Guarda solo las
próximas horas de programación para que el archivo sea ligero en el iPhone.
"""
import datetime as dt
import gzip
import io
import json
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

# Guías XMLTV públicas (las mismas que usa Free-TV/IPTV en su x-tvg-url).
SOURCES = [
    "https://epgshare01.online/epgshare01/epg_ripper_PE1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_MX1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_AR1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_CL1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_CO1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_EC1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_UY1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_PA1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_CR1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_DO1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_ES1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_RAKUTEN_ES1.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_DIRECTVSPORTS1.xml.gz",
]
HOURS_AHEAD = 20


def parse_time(value):
    # Formato XMLTV: 20261125060000 +0000
    value = value.strip()
    base = dt.datetime.strptime(value[:14], "%Y%m%d%H%M%S")
    offset = value[14:].strip()
    if offset:
        sign = 1 if offset[0] == "+" else -1
        delta = dt.timedelta(hours=int(offset[1:3]), minutes=int(offset[3:5]))
        base = base - sign * delta
    return base.replace(tzinfo=dt.timezone.utc).timestamp()


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return data


def main(output):
    now = time.time()
    limit = now + HOURS_AHEAD * 3600
    channels = {}
    for url in SOURCES:
        try:
            data = fetch(url)
        except Exception as error:  # una guía caída no debe romper las demás
            print(f"FALLO {url}: {error}")
            continue
        count = 0
        for _, element in ET.iterparse(io.BytesIO(data), events=("end",)):
            if element.tag != "programme":
                if element.tag == "channel":
                    element.clear()
                continue
            try:
                start = parse_time(element.get("start", ""))
                stop = parse_time(element.get("stop", ""))
            except ValueError:
                element.clear()
                continue
            if stop > now and start < limit:
                title = (element.findtext("title") or "").strip()[:80]
                key = element.get("channel", "").split("@")[0].strip().lower()
                if key and title:
                    channels.setdefault(key, []).append({"s": int(start), "e": int(stop), "t": title})
                    count += 1
            element.clear()
        print(f"OK {url}: {count} programas")

    for key, items in channels.items():
        items.sort(key=lambda item: item["s"])
        unique = []
        for item in items:
            if not unique or item["s"] >= unique[-1]["e"] or item["s"] != unique[-1]["s"]:
                unique.append(item)
        channels[key] = unique

    with open(output, "w", encoding="utf-8") as handle:
        json.dump({"generated": int(now), "channels": channels}, handle, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(channels)} canales con guía")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "epg.json")
