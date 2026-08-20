# Client-side redaction for memory-file sync (session-end.sh). Applied with
# `sed -E -f` before content leaves the machine; the server applies its own
# net again (rag-api src/utils/redact.ts) before embedding. Keep the two in
# sync when adding rules.
# reka project API keys
s/rk_[a-z0-9-]+_[0-9a-f]{6,}/rk_<redacted>/g
# Anthropic / OpenAI-style keys
s/sk-ant-[A-Za-z0-9_-]{8,}/sk-ant-<redacted>/g
s/\bsk-[A-Za-z0-9_-]{20,}/sk-<redacted>/g
# GitHub tokens
s/\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/gh_<redacted>/g
s/\bgithub_pat_[A-Za-z0-9_]{20,}\b/gh_<redacted>/g
# Slack tokens
s/\bxox[baprs]-[A-Za-z0-9-]{10,}/xox<redacted>/g
# Hugging Face tokens
s/\bhf_[A-Za-z0-9]{20,}\b/hf_<redacted>/g
# AWS access key ids
s/\b(AKIA|ASIA)[0-9A-Z]{16}\b/AKIA<redacted>/g
# JWTs
s/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/<redacted-jwt>/g
# Connection-string credentials: scheme://user:password@host
s#(://[^[:space:]:/@]+):[^[:space:]@]+@#\1:<redacted>@#g
# Explicit secret assignments incl. env-var names (DB_PASSWORD=, JWT_SECRET=,
# SESSION_TOKEN=, api_key: ... ; mirrors rag-api src/utils/redact.ts)
s/(([A-Za-z0-9]+[_-])*([Pp]ass(word|wd)?|[Pp]wd|пароль|[Ss]ecret|SECRET|[Tt]oken|TOKEN|PASS(WORD|WD)?|api[_-]?key|API[_-]?KEY|access[_-]?key|ACCESS[_-]?KEY)s?["']?[[:space:]]*[:=][[:space:]]*["']?)[^[:space:]"'`,;]{4,}/\1<redacted>/g
# Bearer headers
s/(Bearer[[:space:]]+)[A-Za-z0-9._~+/-]{8,}=*/\1<redacted>/g
# Ukrainian phone numbers (keep the operator prefix)
s/(\+?380[0-9]{2})[0-9]{7}/\1*******/g
