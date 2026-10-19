# tools/site

Tests: `node --test` from this folder.

## Status job

`status/publish.mjs` computes `status.json` and pushes it, alone, to the orphan `status` branch of
`~/jarvis`'s origin. The push is never forced. If nothing changed and the committed file is under 1 hour
old, the job skips the push. The job logs one line per run to `~/Library/Logs/jarvis-site-status.log`.
After it publishes `shipped: true`, it unloads itself.

The LaunchAgent `in.jarvis.site-status` runs the job at load and then every hour. The plist points at
this worktree (`~/jarvis-site-wt`), so **removing the worktree breaks the agent**: unload the agent first.
Push auth uses the existing git credential helper.

Load (the agent then also comes back after a restart):

```sh
cp ~/jarvis-site-wt/tools/site/status/in.jarvis.site-status.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/in.jarvis.site-status.plist
```

Check: `launchctl list | grep in.jarvis.site-status` and `tail ~/Library/Logs/jarvis-site-status.log`.

Unload, and stop the agent from loading again at the next login:

```sh
launchctl bootout gui/$UID/in.jarvis.site-status
rm ~/Library/LaunchAgents/in.jarvis.site-status.plist
```

When the job unloads itself after shipping, the copy in `~/Library/LaunchAgents` is still there. Delete
it as well, or the agent loads again at the next login.

Run it once by hand: `node status/publish.mjs` (add `--remote <url-or-path>` to publish somewhere else).
