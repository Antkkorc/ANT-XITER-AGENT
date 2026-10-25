import { createWorker, OEM } from 'tesseract.js'

type ProgressDetail = {
  status: string
  progress?: number
}

type TesseractProgress = {
  status?: string
  progress?: number
}

let workerPromise: ReturnType<typeof createWorker> | undefined

function reportProgress(message: TesseractProgress) {
  const detail: ProgressDetail = {
    status: message.status || 'Preparing scanner',
    progress: typeof message.progress === 'number' ? message.progress : undefined,
  }
  window.dispatchEvent(new CustomEvent<ProgressDetail>('ant:ocr-progress', { detail }))
}

export async function recognizeFrame(frame: HTMLCanvasElement): Promise<string> {
  if (!workerPromise) {
    workerPromise = createWorker('eng', OEM.LSTM_ONLY, {
      logger: reportProgress,
    })
  }

  try {
    const worker = await workerPromise
    const result = await worker.recognize(frame)
    return result.data.text.replace(/\r/g, '').trim()
  } catch (error) {
    workerPromise = undefined
    throw error
  }
}
