# aigoodbye.ai website

- Hosting: GitHub Pages for this repo, built from branch `claude/offline-ai-with-internet-4BRpa`, folder `/docs`
  (that branch is also the repo's default branch). `release/3.0` keeps a mirror copy in `docs/` but is NOT what is served.
  To publish: commit to `docs/` on the Pages branch and push; the site updates in about a minute.
- Custom domain: `docs/CNAME` = aigoodbye.ai. DNS at GoDaddy: four A records to GitHub (185.199.108-111.153),
  `www` CNAME to `dealer-of-happiness.github.io` (changed 2026-10-18 so www gets a valid certificate).
- aigoodbye.net, aigoodbye.org, aigoodbye.cloud: GoDaddy permanent (301) forwarding to https://aigoodbye.ai (2026-10-18).
- aigoodbye.com is NOT ours (owned by a domain reseller).
- No email on aigoodbye.ai (no MX). Contact address on the site: marketing@dealerofhappiness.com.
- `docs/version.json` is kept for old desktop app update checks; `thank-you.html` redirects home (old desktop checkout).
- Site has no third-party requests (no Google Fonts, no QR service, no analytics). Keep it that way: the privacy policy says so.
- App Store link: https://apps.apple.com/app/id6757513032 (Smart App Banner meta tag on every page).
