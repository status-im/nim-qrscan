## DecodeWorker: decodes on one background thread, one job at a time.
##
## - `submit` hands over an owned copy of an image; it is rejected (false) while
##   a job is in flight, so callers never build a backlog.
## - The thread blocks on its job channel: no timers, no polling, nothing runs
##   while idle.
## - Results are collected with `tryTakeResult`. `onReady` (optional, nimcall,
##   called on the worker thread) lets a host wake its own thread, e.g. post to
##   the Qt GUI thread.
## - `stop` finishes the job in flight and joins the thread; dropping the last
##   reference does the same automatically.

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

proc shutdownWorker(s: ptr WorkerState, t: Thread[ptr WorkerState]) =
  ## Shared by stop() and the destructor: quit message, join, free.
  {.cast(raises: []).}:
    s.jobs.send(Msg(quit: true))
    joinThread(t)
  s.jobs.close()
  s.results.close()
  deallocShared(s)

proc `=destroy`(w: DecodeWorkerObj) =
  if w.running and w.state != nil:
    shutdownWorker(w.state, w.thread)
  # The other fields (a Thread with a nimcall body and a ptr argument, a bool)
  # own no managed memory.

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

proc isRunning*(w: DecodeWorker): bool =
  ## False once stopped.
  w.running

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
  ## Idempotent; also done automatically when the worker is destroyed.
  if not w.running:
    return
  w.running = false
  shutdownWorker(w.state, w.thread)
  w.state = nil

