## Built by scripts/install-check.sh against an installed qrscan package.
import results
import qrscan

let blank = newSeq[byte](64 * 64)
doAssert decode(lumaView(blank, 64, 64, 64)).get.len == 0
echo "qrscan installed package: ok"
