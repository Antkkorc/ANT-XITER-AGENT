import 'dotenv/config'
import express from 'express'
import answersHandler from '../api/answers.js'

const app = express()
const port = Number(process.env.API_PORT || 3001)

app.use(express.json({ limit: '64kb' }))
app.all('/api/answers', (req, res) => answersHandler(req, res))
app.get('/healthz', (_req, res) => res.json({ ok: true }))

app.listen(port, '0.0.0.0', () => {
  console.log(`ANT API ready on port ${port}`)
})
