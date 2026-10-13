## DecodeWorker: decodes on one background thread, one job at a time.
##
## - `submit` hands over an owned copy of an image; it is rejected (false) while
##   a job is in flight, so callers never build a backlog.
## - The thread blocks on its job channel: no timers, no polling, nothing runs
##   while idle.
## - Results are collected with `tryTakeResult`. `onReady` (optional, nimcall,
##   called on the worker thread) lets a host wake its own thread, e.g. post to
##   the Qt GUI thread.
## - Call `stop` before dropping the worker.

{.push raises: [], gcsafe.}

import std/[atomics, monotimes, times]
import results
import ./[types, decode]

export results, types

type
  DecodeJob* = object
    id*: int           ## caller's tag (e.g. a scanner handle)
    data*: seq[byte]   ## owned grayscale pixels
    width*, height*, rowStride*: int
    opts*: DecodeOptions

  DecodeOutcome* = object
    id*: int
    codes*: seq[DecodedCode]
    error*: Opt[DecodeError]
    decodeMs*: float

  ResultReady* = proc() {.gcsafe, raises: [], nimcall.}

  Msg = object
    quit: bool
    job: DecodeJob

  WorkerState = object
    jobs: Channel[Msg]
    results: Channel[DecodeOutcome]
    busy: Atomic[bool]
    onReady: ResultReady

  DecodeWorkerObj = object
    state: ptr WorkerState
    thread: Thread[ptr WorkerState]
    running: bool

  DecodeWorker* = ref DecodeWorkerObj

proc workerLoop(s: ptr WorkerState) {.thread, raises: [].} =
  while true:
    var msg: Msg
    {.cast(raises: []).}:
      msg = s.jobs.recv()
    if msg.quit:
      break
    let t0 = getMonoTime()
    let r = decode(lumaView(msg.job.data, msg.job.width, msg.job.height,
                            msg.job.rowStride), msg.job.opts)
    var outcome = DecodeOutcome(id: msg.job.id,
                                decodeMs: (getMonoTime() - t0).inMicroseconds.float / 1000.0)
    if r.isOk:
      outcome.codes = r.get
    else:
      outcome.error = Opt.some(r.error)
    {.cast(raises: []).}:
      s.results.send(outcome)
    s.busy.store(false)
    if s.onReady != nil:
      s.onReady()

proc newDecodeWorker*(onReady: ResultReady = nil): DecodeWorker =
  let s = cast[ptr WorkerState](allocShared0(sizeof(WorkerState)))
  s.jobs.open()
  s.results.open()
  s.onReady = onReady
  let w = DecodeWorker(state: s, running: true)
  {.cast(raises: []).}:
    createThread(w.thread, workerLoop, s)
  w

proc busy*(w: DecodeWorker): bool =
  w.running and w.state.busy.load()

proc submit*(w: DecodeWorker, job: sink DecodeJob): bool =
  ## False if a job is in flight or the worker is stopped.
  if not w.running:
    return false
  var expected = false
  if not w.state.busy.compareExchange(expected, true):
    return false
  {.cast(raises: []).}:
    w.state.jobs.send(Msg(job: job))
  true

proc tryTakeResult*(w: DecodeWorker): Opt[DecodeOutcome] =
  ## Non-blocking; any thread.
  if w.state == nil:
    return Opt.none(DecodeOutcome)
  let (ok, outcome) = w.state.results.tryRecv()
  if ok: Opt.some(outcome) else: Opt.none(DecodeOutcome)

proc stop*(w: DecodeWorker) =
  ## Finishes the job in flight, joins the thread and frees the channels.
  ## Idempotent.
  if not w.running:
    return
  w.running = false
  {.cast(raises: []).}:
    w.state.jobs.send(Msg(quit: true))
    joinThread(w.thread)
  w.state.jobs.close()
  w.state.results.close()
  deallocShared(w.state)
  w.state = nil
