#!/usr/bin/env make
.PHONY: run_website stop_website

run_website:
	podman build --platform linux/arm64 -t explorecalifornia.com . && \
		podman run --rm --name explorecalifornia.com -p 5001:80 -d explorecalifornia.com

stop_website:
	podman stop explorecalifornia.com
