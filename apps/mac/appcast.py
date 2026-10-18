#!/usr/bin/env python3
"""Sparkle appcast for Kestrel for Mac (one item: the build CI just made).

  appcast.py feed --build N --short 1.2 --url URL --length BYTES --signature SIG \
      [--notes FILE] > appcast.xml
  appcast.py verify --public-key B64 --signature SIG FILE

`feed` writes the appcast; CI then has Sparkle's sign_update sign the feed
itself, since the app sets SURequireSignedFeed. `verify` checks an EdDSA
signature from sign_update against the public key the app trusts (needs the
cryptography package).
"""
import argparse
import base64
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

MIN_MACOS = "14.0"


def feed(a):
    notes = open(a.notes).read().strip() if a.notes else ""
    notes_xml = f'\n      <description sparkle:format="markdown"><![CDATA[{notes.replace("]]>", "]] >")}]]></description>' if notes else ""
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kestrel for Mac</title>
    <link>https://github.com/mandipadk/kestrel/releases/tag/mac-latest</link>
    <language>en</language>
    <item>
      <title>Kestrel {escape(a.short)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_MACOS}</sparkle:minimumSystemVersion>{notes_xml}
      <enclosure url={quoteattr(a.url)} length="{int(a.length)}" type="application/octet-stream" sparkle:edSignature={quoteattr(a.signature)} />
    </item>
  </channel>
</rss>""")


def verify(a):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(a.public_key))
    try:
        key.verify(base64.b64decode(a.signature), open(a.file, "rb").read())
    except InvalidSignature:
        sys.exit(f"{a.file}: the EdDSA signature does not match the app's public key")
    print(f"ok    {a.file} is signed with the key the app trusts")


p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
f = sub.add_parser("feed")
for opt in ("build", "short", "url", "length", "signature"):
    f.add_argument(f"--{opt}", required=True)
f.add_argument("--notes")
v = sub.add_parser("verify")
v.add_argument("--public-key", required=True)
v.add_argument("--signature", required=True)
v.add_argument("file")
a = p.parse_args()
feed(a) if a.cmd == "feed" else verify(a)
