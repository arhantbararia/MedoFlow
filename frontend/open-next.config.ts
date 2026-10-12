import { defineCloudflareConfig } from '@opennextjs/cloudflare'

// No incremental cache: every page in this app is client-rendered or dynamic,
// so there is nothing to persist between requests (no R2/KV binding needed).
export default defineCloudflareConfig()
