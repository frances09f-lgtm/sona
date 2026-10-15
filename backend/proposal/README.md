# Always-on paper protection — integration proposal, not a deployed feature

The repository has public client RPC names and a Supabase project URL but no SQL/RPC source, scheduler configuration, authenticated Supabase administrative connection or schema export. We did not query a real paper account or change a live backend. A publishable API key is not deployment authority. Do not advertise dependable off-device execution in this release.

`001_protection.sql` is an additive, isolated migration proposal. It stores central per-position limits and one execution record per position. Scheduler evaluation uses source timestamps, executable bid/ask, transaction row locks, uniqueness and a required atomic close-if-open adapter. It does not assume, rename or overwrite existing account/position tables. No grants or scheduler are installed. Three adapter functions deliberately raise integration-required errors. It is not a completed production integration.

Smallest missing dependency: backend source/schema plus an authorized deployment route for the existing Supabase project (`ncaialkmxhbtarmhoiei`), including `paper_open`, `paper_close`, `paper_state` and PIN/account ownership checks. An admin export/repository or connected project-access route is sufficient; never paste service-role keys/passwords into chat.

Required before enabling:
1. Implement the three adapters against actual tables. Lock the same position in BOTH manual paper_close and scheduled close. Update balance exactly once in the same DB transaction; don't call HTTP paper_close from SQL.
2. Integrate central limits creation into paper_open; server-authoritative read-back and edit RPCs must replace client-local overrides, with explicit backfill decisions for conflicting device limits. Don't guess old settings.
3. Deploy a trusted server-side scheduler/Edge Function to fetch Swissquote BBO and preserve its source timestamp; call the service-only tick RPC. Handle outages with visible heartbeat/health, not silent successful ticks. Never embed service-role credentials in Flutter.
4. Authenticate limits/execution read RPCs and notification delivery. Transactional notification outbox must only emit verified executions, with dedupe per execution and auditable actual fill, quote timestamp and detection time.
5. Test simultaneous manual close/scheduler ticks/two clients, retries, stale/crossed/missing quotes, gaps, PIN/auth failures, locks and recovery against a disposable database. SQL here was syntax-parsed only, not executed on Postgres.
6. Capability RPC stays false until the complete path is verified. The app must additionally check recent scheduler health before displaying enabled status. Only then may client timers be disabled. The current release does not implement this integration.

The shipped client mitigation remains best-effort WorkManager checks (minimum roughly 15 minutes, delayed or stopped by Android/OEM) and foreground checks. It rejects stale/missing quote timestamps and keeps a device-local durable close ledger shared by isolates. A timeout/5xx is uncertain and blocks resubmission until a confirmed closed state appears. It cannot guarantee cross-device dedupe without backend close-if-open. Limits edited after opening remain device-local. Restoring missing backend access must not trigger a blind deployment.
