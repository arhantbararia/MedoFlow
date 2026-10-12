/**
 * BullMQ durability smoke test for a deployed environment (D0.3).
 *
 *   node scripts/deploy/queue-smoke.js enqueue <n>   # add n jobs, no worker running
 *   node scripts/deploy/queue-smoke.js work          # drain the queue in a fresh process
 *
 * Running `enqueue`, then restarting/redeploying, then `work` in a new process proves
 * jobs survive a restart. `work` exits non-zero if any job is lost or completes twice.
 * Uses REDIS_URL, the same variable as the API.
 */
const { Queue, Worker } = require('bullmq')

const QUEUE = 'deploy-smoke'
const url = new URL(process.env.REDIS_URL || 'redis://localhost:6379')
const connection = {
  host: url.hostname,
  port: Number(url.port || 6379),
  username: url.username || undefined,
  password: url.password ? decodeURIComponent(url.password) : undefined,
  tls: url.protocol === 'rediss:' ? {} : undefined,
  maxRetriesPerRequest: null,
}

async function enqueue(n) {
  const queue = new Queue(QUEUE, { connection })
  await queue.obliterate({ force: true })
  for (let i = 0; i < n; i++) {
    await queue.add('smoke', { i }, { jobId: `smoke-${i}`, removeOnComplete: false })
  }
  console.log(`enqueued ${n}; waiting=${await queue.getWaitingCount()}`)
  await queue.close()
}

async function work() {
  const queue = new Queue(QUEUE, { connection })
  const expected = (await queue.getWaitingCount()) + (await queue.getCompletedCount())
  const seen = new Map()
  const worker = new Worker(
    QUEUE,
    async (job) => {
      seen.set(job.id, (seen.get(job.id) || 0) + 1)
      return { ok: true }
    },
    { connection }
  )
  const deadline = Date.now() + 60_000
  while ((await queue.getCompletedCount()) < expected && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 500))
  }
  await worker.close()
  const completed = await queue.getCompletedCount()
  const dupes = [...seen.values()].filter((c) => c > 1).length
  console.log(
    `expected=${expected} completed=${completed} processedNow=${seen.size} duplicates=${dupes}`
  )
  await queue.obliterate({ force: true })
  await queue.close()
  process.exit(completed === expected && dupes === 0 ? 0 : 1)
}

const [cmd, arg] = process.argv.slice(2)
;(cmd === 'enqueue' ? enqueue(Number(arg || 10)) : work()).catch((err) => {
  console.error(err.message)
  process.exit(1)
})
