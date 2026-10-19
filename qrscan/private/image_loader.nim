## ImageLoader: loads picked image files on one background thread, so a large
## photo never stalls the GUI. Same lifecycle and memory rules as DecodeWorker
## (see worker.nim): the thread blocks on its job channel (nothing runs while
## idle), results are taken with `tryTakeResult` (copied into the caller's
## heap), `onReady` wakes the host's thread, and `stop` / dropping the last
## reference joins the thread. Unlike the decode worker, jobs may queue: the
## GUI side drops results that a newer request superseded.

{.push raises: [], gcsafe.}

import std/atomics
import results
import ./image_load

export image_load

type
  LoadOutcome* = object
    id*: int
    image*: LoadedImage
    error*: Opt[LoadError]

  LoaderReady* = proc() {.gcsafe, raises: [], nimcall.}

  Msg = object
    quit: bool
    id: int
    path: string
    maxDim: int

  LoaderState = object
    jobs: Channel[Msg]
    results: Channel[LoadOutcome]
    pending: Atomic[int]
    onReady: LoaderReady

  ImageLoaderObj = object
    state: ptr LoaderState
    thread: Thread[ptr LoaderState]
    running: bool

  ImageLoader* = ref ImageLoaderObj

proc shutdownLoader(s: ptr LoaderState, t: Thread[ptr LoaderState]) =
  {.cast(raises: []).}:
    s.jobs.send(Msg(quit: true))
    joinThread(t)
  s.jobs.close() # the results channel is closed by the loader (loaderLoop)
  deallocShared(s)

proc `=destroy`(l: ImageLoaderObj) =
  if l.running and l.state != nil:
    shutdownLoader(l.state, l.thread)

proc loaderLoop(s: ptr LoaderState) {.thread, raises: [].} =
  while true:
    var msg: Msg
    {.cast(raises: []).}:
      msg = s.jobs.recv()
    if msg.quit:
      break
    var outcome = LoadOutcome(id: msg.id)
    let r = loadImageFile(msg.path, msg.maxDim)
    if r.isOk:
      outcome.image = r.get
    else:
      outcome.error = Opt.some(r.error)
    {.cast(raises: []).}:
      s.results.send(outcome)
    discard s.pending.fetchSub(1)
    if s.onReady != nil:
      s.onReady()
  # Free what stays on this thread's side while it is alive (see worker.nim).
  while true:
    var taken: bool
    {.cast(raises: []).}:
      taken = s.results.tryRecv().dataAvailable
    if not taken:
      break
  s.results.close()

proc newImageLoader*(onReady: LoaderReady = nil): ImageLoader =
  let s = cast[ptr LoaderState](allocShared0(sizeof(LoaderState)))
  s.jobs.open()
  s.results.open()
  s.onReady = onReady
  let l = ImageLoader(state: s, running: true)
  {.cast(raises: []).}:
    createThread(l.thread, loaderLoop, s)
  l

proc submit*(l: ImageLoader, id: int, path: string, maxDim: int): bool =
  ## Queues a load; false once stopped.
  if not l.running:
    return false
  discard l.state.pending.fetchAdd(1)
  {.cast(raises: []).}:
    l.state.jobs.send(Msg(id: id, path: path, maxDim: maxDim))
  true

func copyOf(o: LoadOutcome): LoadOutcome =
  o

proc tryTakeResult*(l: ImageLoader): Opt[LoadOutcome] =
  ## Non-blocking; call it from the thread that stops the loader.
  if l.state == nil:
    return Opt.none(LoadOutcome)
  let (ok, received) = l.state.results.tryRecv()
  if not ok:
    return Opt.none(LoadOutcome)
  Opt.some(copyOf(received))

proc stop*(l: ImageLoader) =
  ## Finishes the load in flight, joins the thread and frees the channels.
  if not l.running:
    return
  l.running = false
  shutdownLoader(l.state, l.thread)
  l.state = nil
