# ctx-eng-book Substack drafts

A CronJob that creates the Substack draft for each scheduled book post and
tags Miriah in Discord `#pedrogpt`. Source lives in
[`ctx-eng-book`](https://github.com/Soypete/ctx-eng-book).

- **Namespace**: `ctx-eng-book`
- **CronJob**: `substack-draft`, `0 7 * * 1,3,5` in `America/Denver`
- **Image**: `python:3.12-slim` (no custom image; see below)

## What a run does

1. Downloads `main` of ctx-eng-book as a tarball into an `emptyDir`.
2. Runs `scripts/substack_draft.py --scheduled`, which finds today's row in
   `book/substack/SCHEDULE.md`:
   - no row today, or status `published` → exits cleanly, no draft
   - `post.md` missing or the Substack call fails → Discord failure ping, job fails
   - otherwise → creates the draft and pings Discord with its link

It only creates drafts. Publishing stays manual.

Because each run reads `main`, merging a post or schedule change is the
deploy. Nothing needs rebuilding.

`backoffLimit: 0` is deliberate: a retry after a partial failure could create
a duplicate draft.

## Deploying

```bash
export KUBECONFIG=~/.foundry/kubeconfig
kubectl apply -k k8s/ctx-eng-book

# Secret from ctx-eng-book's git-ignored .env
kubectl create secret generic ctx-eng-book-secrets -n ctx-eng-book \
  --from-env-file=$HOME/Code/misc/ctx-eng-book/.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

The Secret holds `SUBSTACK_SESSION_COOKIE`, `DISCORD_SECRET` (the Pedro bot
token, OpenBao `secret/pedro/discord` field `token`), and `DISCORD_USER_ID`.
It uses a plain Secret rather than OpenBao injection, matching pedro-agents,
until a `ctx-eng-book` OpenBao role exists.

## Refreshing the Substack cookie

`SUBSTACK_SESSION_COOKIE` is a browser session cookie and expires. When it
does, runs fail with a 401/403 and the Discord ping says so. Update `.env`
and re-run the secret command above.

## Checking on it

```bash
kubectl get cronjob,jobs -n ctx-eng-book
kubectl logs -n ctx-eng-book -l app.kubernetes.io/name=substack-draft --tail=50

# Trigger a run by hand (drafts today's post, if one is scheduled)
kubectl create job -n ctx-eng-book manual-draft --from=cronjob/substack-draft
```
