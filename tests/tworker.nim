import std/[unittest, os, monotimes, times, osproc, strutils]
import results
import ../qrscan, ../qrscan/worker
import ./qrgen

proc job(text: string, id = 1): DecodeJob =
  let g = qrImage(text)
  DecodeJob(id: id, data: g.data, width: g.width, height: g.height,
            rowStride: g.rowStride, opts: DecodeOptions.init())

proc waitResult(w: DecodeWorker, timeoutMs = 5000): Opt[DecodeOutcome] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let r = w.tryTakeResult()
    if r.isSome:
      return r
    sleep(2)
  Opt.none(DecodeOutcome)

proc liveThreadCount(): int =
  ## Threads of this process (macOS: ps -M; Linux: /proc/self/task).
  when defined(linux):
    for _ in walkDir("/proc/self/task"):
      inc result
  else:
    let listing = execProcess("ps", args = ["-M", $getCurrentProcessId()],
                          options = {poUsePath})
    result = listing.strip.splitLines.len - 1 # minus the header line

proc dropIdleWorkers(n: int) =
  for i in 0 ..< n:
    let w = newDecodeWorker()
    check w.isRunning # dropped at the end of each iteration, never stopped

proc dropBusyWorker() =
  let w = newDecodeWorker()
  let noise = GrayImage(width: 1500, height: 1500, rowStride: 1500,
                        data: newSeq[byte](1500 * 1500)).withNoise(127, 13)
  check w.submit(DecodeJob(id: 9, data: noise.data, width: noise.width,
                           height: noise.height, rowStride: noise.rowStride,
                           opts: DecodeOptions.init()))
  # dropped with a decode in flight

proc stopThenDrop() =
  let w = newDecodeWorker()
  w.stop()
  w.stop()
  # destroyed after an explicit stop: must not stop/free twice

var readyCount: int # touched from the worker thread through onReady

proc onReadyForTest() {.gcsafe, raises: [], nimcall.} =
  {.cast(gcsafe).}:
    discard atomicInc(readyCount)

suite "DecodeWorker":
  test "decodes off-thread and reports the job id":
    let w = newDecodeWorker()
    check w.submit(job("worker", id = 42))
    let r = w.waitResult().get
    check r.id == 42
    check r.error.isNone
    check r.codes.len == 1
    check r.codes[0].text == "worker"
    check r.decodeMs >= 0
    w.stop()

  test "submit while busy is rejected": # Review Focus 1
    let w = newDecodeWorker()
    # A large noisy image with no code keeps the worker busy far longer than
    # the microseconds between the two submits below.
    let noise = GrayImage(width: 3000, height: 3000, rowStride: 3000,
                          data: newSeq[byte](3000 * 3000)).withNoise(127, 11)
    check w.submit(DecodeJob(id: 1, data: noise.data, width: noise.width,
                             height: noise.height, rowStride: noise.rowStride,
                             opts: DecodeOptions.init()))
    check w.busy
    check not w.submit(job("second"))
    check w.waitResult(20_000).get.id == 1
    check not w.busy
    check w.submit(job("third", id = 3))
    let r = w.waitResult().get
    check r.id == 3
    check r.codes[0].text == "third"
    check w.tryTakeResult().isNone # the rejected job produced nothing
    w.stop()

  test "invalid job yields an error outcome":
    let w = newDecodeWorker()
    check w.submit(DecodeJob(id: 3, data: @[], width: 10, height: 10, rowStride: 10))
    let r = w.waitResult().get
    check r.id == 3
    check r.error.isSome
    check r.error.get.kind == dekInvalidInput
    w.stop()

  test "onReady fires once per result":
    readyCount = 0
    let w = newDecodeWorker(onReadyForTest)
    check w.submit(job("ready"))
    discard w.waitResult()
    check readyCount == 1
    w.stop()

  test "stop while busy joins promptly": # Review Focus 3
    let w = newDecodeWorker()
    discard w.submit(job("stopping"))
    let t0 = getMonoTime()
    w.stop()
    check (getMonoTime() - t0).inMilliseconds < 3000
    w.stop() # idempotent
    check not w.submit(job("after stop"))

  test "many sequential jobs do not leak results":
    let w = newDecodeWorker()
    for i in 0 ..< 50:
      check w.submit(job("n" & $i, id = i))
      check w.waitResult().get.id == i
    check w.tryTakeResult().isNone
    w.stop()

  test "results outlive the worker thread": # Windows CI: SIGSEGV in stop()
    # Under ORC a thread's heap header dies with the thread, so memory the
    # worker allocated must not be freed by another thread after it exits:
    # not the results channel's buffer (allocated by the worker's first send),
    # not a result still queued at stop, not a result the caller holds.
    # Windows faults on such a free; elsewhere `make test-asan` reports it.
    var held: DecodeOutcome
    block:
      let w = newDecodeWorker()
      check w.submit(job("held", id = 5))
      held = w.waitResult().get
      check w.submit(job("queued", id = 6))
      while w.busy:
        sleep(2)
      w.stop() # result 6 is never taken
    check held.id == 5
    check held.codes[0].text == "held"
    held = DecodeOutcome() # frees the taken result after the worker exited
    check held.codes.len == 0

  test "dropping a worker stops and joins its thread": # review: Task 3 cleanup
    when defined(windows):
      skip() # counts threads with ps (macOS) / /proc (Linux)
    else:
      let base = liveThreadCount()
      dropIdleWorkers(24)
      check liveThreadCount() <= base
      dropBusyWorker()
      check liveThreadCount() <= base
      stopThenDrop()
      check liveThreadCount() <= base
