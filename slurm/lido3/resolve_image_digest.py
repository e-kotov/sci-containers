#!/usr/bin/env python3
"""Resolve an OCI image tag to the requested Linux platform manifest digest."""
from __future__ import print_function

import json
import re
import sys
import urllib.parse
import urllib.request


ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))


def fail(message):
    sys.stderr.write("resolve_image_digest: %s\n" % message)
    raise SystemExit(1)


def main(argv):
    if len(argv) not in (3, 4):
        fail("usage: resolve_image_digest.py <registry/repository> <tag> [architecture]")
    image, tag = argv[1], argv[2]
    architecture = argv[3] if len(argv) == 4 else "amd64"
    if ":" in image or "@" in image or "/" not in image:
        fail("image must be registry/repository without tag or digest")
    host, repository = image.split("/", 1)
    if host != "ghcr.io":
        fail("only public ghcr.io images are supported")

    token_query = urllib.parse.urlencode({
        "service": "ghcr.io",
        "scope": "repository:%s:pull" % repository,
    })
    token_url = "https://ghcr.io/token?%s" % token_query
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(token_url, timeout=30) as response:
            token = json.loads(response.read().decode("utf-8"))["token"]
        manifest_url = "https://%s/v2/%s/manifests/%s" % (host, repository, tag)
        request = urllib.request.Request(manifest_url, headers={
            "Authorization": "Bearer " + token,
            "Accept": ACCEPT,
        })
        with opener.open(request, timeout=60) as response:
            manifest = json.loads(response.read().decode("utf-8"))
            digest = response.headers.get("Docker-Content-Digest", "")
    except Exception as exc:
        fail("registry lookup failed: %s" % exc)

    if "manifests" in manifest:
        candidates = [entry for entry in manifest["manifests"]
                      if entry.get("platform", {}).get("os") == "linux"
                      and entry.get("platform", {}).get("architecture") == architecture]
        if len(candidates) != 1:
            fail("expected one linux/%s manifest for %s:%s, found %d" %
                 (architecture, image, tag, len(candidates)))
        digest = candidates[0].get("digest", "")
    if not re.match(r"^sha256:[0-9a-f]{64}$", digest):
        fail("registry returned no full sha256 manifest digest")
    print(digest)


if __name__ == "__main__":
    main(sys.argv)
