#!/usr/bin/env python3
"""Validates altstore/source.json against AltStore's documented source format
(https://faq.altstore.io/developers/make-a-source) and, optionally, against an
unzipped ADP and the live URLs. AltStore publishes no schema; this encodes the
documented keys, types and enums plus what AltStore PAL needs from an ADP.

    python3 -I altstore/validate.py [source.json] [--adp DIR] [--online]

Exit 0 if valid. Standard library only.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

CATEGORIES = {"developer", "entertainment", "games", "lifestyle", "other",
              "photo-video", "social", "utilities"}
HEX = re.compile(r"^#?[0-9A-Fa-f]{6}$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2}))?$")
FEDI = re.compile(r"^[a-z0-9_]{1,30}$")  # conservative: Mastodon-style local part
# AltStore ignores only these two when comparing entitlements (VerifyAppOperation)
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}

errors, warnings, urls = [], [], []


def err(msg):
    errors.append(msg)


def typed(obj, key, kind, where, required=True):
    if key not in obj:
        if required:
            err(f"{where}: missing required `{key}`")
        return None
    val = obj[key]
    if kind is int and isinstance(val, bool) or not isinstance(val, kind):
        err(f"{where}.{key}: expected {kind.__name__}, got {type(val).__name__}")
        return None
    return val


def url(obj, key, where, required=True):
    val = typed(obj, key, str, where, required)
    if val is not None:
        if not val.startswith("https://"):
            err(f"{where}.{key}: not an https URL: {val}")
        urls.append(val)
    return val


def validate(src, adp):
    w = "source"
    typed(src, "name", str, w)
    for k in ("subtitle", "description"):
        typed(src, k, str, w, required=False)
    for k in ("iconURL", "headerURL", "website", "patreonURL"):
        url(src, k, w, required=False)
    tint = typed(src, "tintColor", str, w, required=False)
    if tint and not HEX.match(tint):
        err(f"{w}.tintColor: not hex: {tint}")
    fedi = typed(src, "fediUsername", str, w, required=False)
    if fedi is not None:
        if not FEDI.match(fedi):
            err(f"{w}.fediUsername: use 1-30 of a-z 0-9 _ (no @): {fedi!r}")
        # Discovery makes nsfw mandatory
        typed(src, "nsfw", bool, w)
    else:
        typed(src, "nsfw", bool, w, required=False)
        warnings.append("no fediUsername: the source cannot be federated")
    if "identifier" in src:
        warnings.append("top-level `identifier` is not in the current docs "
                        "(kept for older AltStore clients; harmless)")

    apps = typed(src, "apps", list, w) or []
    bundle_ids = [a.get("bundleIdentifier") for a in apps if isinstance(a, dict)]
    if len(bundle_ids) != len(set(bundle_ids)):
        err("source.apps: duplicate bundleIdentifier")
    featured = typed(src, "featuredApps", list, w, required=False) or []
    for b in featured:
        if b not in bundle_ids:
            err(f"source.featuredApps: {b} is not an app in this source")
    if len(featured) > 5:
        warnings.append("featuredApps: only the first five are shown")

    for i, app in enumerate(apps):
        validate_app(app, f"apps[{i}]", adp)

    news = typed(src, "news", list, w, required=False) or []
    ids = []
    for i, n in enumerate(news):
        nw = f"news[{i}]"
        for k in ("title", "identifier", "caption", "date"):
            typed(n, k, str, nw)
        ids.append(n.get("identifier"))
        if isinstance(n.get("date"), str) and not ISO_DATE.match(n["date"]):
            err(f"{nw}.date: not ISO 8601: {n['date']}")
    if len(ids) != len(set(ids)):
        err("news: identifiers must be unique")


def validate_app(app, w, adp):
    for k in ("name", "bundleIdentifier", "developerName", "localizedDescription"):
        typed(app, k, str, w)
    mid = typed(app, "marketplaceID", str, w)  # required for PAL (notarized) apps
    if mid is not None and not mid.isdigit():
        err(f"{w}.marketplaceID: should be the numeric Apple ID, as a string")
    url(app, "iconURL", w)
    typed(app, "subtitle", str, w, required=False)
    tint = typed(app, "tintColor", str, w, required=False)
    if tint and not HEX.match(tint):
        err(f"{w}.tintColor: not hex: {tint}")
    cat = typed(app, "category", str, w, required=False)
    if cat and cat not in CATEGORIES:
        err(f"{w}.category: {cat} is not one of {sorted(CATEGORIES)}")

    shots = app.get("screenshots", [])
    groups = shots.items() if isinstance(shots, dict) else [("iphone", shots)]
    for device, items in groups:
        if device not in ("iphone", "ipad"):
            err(f"{w}.screenshots: unknown device key {device}")
        for j, s in enumerate(items):
            sw = f"{w}.screenshots.{device}[{j}]"
            if isinstance(s, str):
                if device == "ipad":
                    err(f"{sw}: iPad screenshots need width and height")
                urls.append(s)
            elif isinstance(s, dict):
                url(s, "imageURL", sw)
                need = device == "ipad"
                typed(s, "width", int, sw, required=need)
                typed(s, "height", int, sw, required=need)
            else:
                err(f"{sw}: expected URL string or object")

    perms = typed(app, "appPermissions", dict, w)
    if perms is not None:
        ents = typed(perms, "entitlements", list, f"{w}.appPermissions") or []
        for e in ents:
            if not isinstance(e, str):
                err(f"{w}.appPermissions.entitlements: entries must be strings")
            elif e in IGNORED_ENTITLEMENTS:
                warnings.append(f"{w}: {e} need not be listed")
        priv = typed(perms, "privacy", dict, f"{w}.appPermissions") or {}
        for k, v in priv.items():
            if not k.endswith("UsageDescription") or not isinstance(v, str):
                err(f"{w}.appPermissions.privacy: {k} must be a *UsageDescription string")

    versions = typed(app, "versions", list, w) or []
    if not versions:
        err(f"{w}.versions: empty")
    for j, v in enumerate(versions):
        vw = f"{w}.versions[{j}]"
        for k in ("version", "buildVersion", "date"):
            typed(v, k, str, vw)
        url(v, "downloadURL", vw)
        size = typed(v, "size", int, vw)
        if isinstance(v.get("date"), str) and not ISO_DATE.match(v["date"]):
            err(f"{vw}.date: not ISO 8601: {v['date']}")
        for k in ("minOSVersion", "maxOSVersion", "localizedDescription", "marketingVersion"):
            typed(v, k, str, vw, required=False)
        if "maxOSVersion" in v:
            warnings.append(f"{vw}: maxOSVersion set; most apps should not use it")
        if adp and j == 0:
            check_adp(app, v, vw, size, adp)


def check_adp(app, v, vw, size, adp):
    m = json.loads((adp / "manifest.json").read_bytes())
    pairs = [("bundleIdentifier", app.get("bundleIdentifier"), m.get("bundleId")),
             ("marketplaceID", app.get("marketplaceID"), m.get("appleItemId")),
             ("version", v.get("version"), m.get("shortVersionString")),
             ("buildVersion", v.get("buildVersion"), m.get("bundleVersion")),
             ("minOSVersion", v.get("minOSVersion", m["minimumSystemVersions"]["ios"]),
              m["minimumSystemVersions"]["ios"])]
    for k, ours, theirs in pairs:
        if ours != theirs:
            err(f"{vw}: {k} {ours!r} != ADP manifest {theirs!r}")
    sizes = {x["variantDetails"]["compressedSize"] for x in m["variants"]}
    if size is not None and size not in sizes:
        err(f"{vw}.size: {size} is not the size of any variant {sorted(sizes)}")
    dl = v.get("downloadURL", "")
    if not (dl.endswith(f"/{m['shortVersionString']}/manifest.json")
            or dl.endswith(f"/{m['shortVersionString']}/")):
        err(f"{vw}.downloadURL: should be the ADP's manifest.json or its folder")


def check_online():
    for u in dict.fromkeys(urls):
        req = urllib.request.Request(u, method="HEAD", headers={"User-Agent": "nfcarchiver-validate"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                if r.status != 200 or r.url != u:
                    err(f"{u}: HTTP {r.status}, ended at {r.url}")
        except Exception as e:  # noqa: BLE001 - report any failure
            err(f"{u}: {e}")


def main(argv):
    path = Path(__file__).with_name("source.json")
    adp, online = None, False
    it = iter(argv)
    for a in it:
        if a == "--adp":
            adp = Path(next(it))
        elif a == "--online":
            online = True
        else:
            path = Path(a)
    validate(json.loads(path.read_bytes()), adp)
    if online:
        check_online()
    for wmsg in warnings:
        print(f"warning: {wmsg}")
    for e in errors:
        print(f"ERROR: {e}")
    print(f"{path}: {'INVALID' if errors else 'valid'} "
          f"({len(urls)} URLs{' checked online' if online else ''})")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
