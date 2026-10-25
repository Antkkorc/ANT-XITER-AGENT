export type StudyAnswer = {
  question: string
  answer: string
  explanation: string
}

export type ApiStatus = {
  ready: boolean
  provider: string
  model: string
}

type AnswerResponse = {
  answers?: StudyAnswer[]
  error?: string
  model?: string
}

export async function getApiStatus(): Promise<ApiStatus> {
  const response = await fetch('/api/answers', { headers: { accept: 'application/json' } })
  if (!response.ok) throw new Error('The answer service is not responding.')
  return response.json() as Promise<ApiStatus>
}

export async function generateAnswers(text: string, mode: 'study' | 'live' = 'study'): Promise<StudyAnswer[]> {
  const response = await fetch('/api/answers', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text, mode }),
  })

  const payload = await response.json().catch(() => ({})) as AnswerResponse
  if (!response.ok) {
    throw new Error(payload.error || 'Could not generate answers. Please try again.')
  }
  if (!Array.isArray(payload.answers)) {
    throw new Error('The answer service returned an unexpected response.')
  }
  return payload.answers
}
