// Cloudflare entry for the MedoFlow frontend. Wraps the OpenNext-generated
// handler (built into .open-next/ by `opennextjs-cloudflare build`) to enforce
// HTTPS and HSTS before any page is rendered.
import { default as handler } from './.open-next/worker.js'

const HSTS = 'max-age=31536000; includeSubDomains'

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    if (url.protocol === 'http:') {
      if (request.method === 'GET' || request.method === 'HEAD') {
        url.protocol = 'https:'
        return Response.redirect(url.toString(), 301)
      }
      return new Response('HTTPS required', { status: 403 })
    }
    const response = await handler.fetch(request, env, ctx)
    const secured = new Response(response.body, response)
    secured.headers.set('strict-transport-security', HSTS)
    return secured
  },
}

export { DOQueueHandler, DOShardedTagCache, BucketCachePurge } from './.open-next/worker.js'
