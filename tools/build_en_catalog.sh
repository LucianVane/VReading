#!/bin/zsh
# 生成英语分级推荐书单 VReading/Resources/Data/recommend_en.json
# 用法: zsh tools/build_en_catalog.sh [工作目录]   (首次运行需下载约 600 本书, 耗时 10-20 分钟)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-/tmp/vreading-en-catalog}
mkdir -p "$WORK/texts"
cd "$WORK"

# 1. EFLLex 英语 CEFR 分级词库 (CC BY-NC-SA 4.0)
if [ ! -s efllex.tsv ]; then
  LINK=$(curl -sL -m 60 https://cental.uclouvain.be/cefrlex/efllex/download/ | grep -oiE 'static/resources/en/[^"]+\.(tsv|csv)' | head -1)
  echo "EFLLex: $LINK"
  curl -sL -m 120 -o efllex.tsv "https://cental.uclouvain.be/cefrlex/$LINK"
fi
head -2 efllex.tsv

# 2. 候选书目
[ -s candidates.json ] || python3 "$ROOT/tools/fetch_gutendex.py" en candidates.json 12

# 3. 并行下载正文
python3 -c "
import json
for b in json.load(open('candidates.json')):
    if b.get('languages') != ['en']: continue
    for k, v in b['formats'].items():
        if k.startswith('text/plain') and not v.endswith('.zip'):
            print(b['id'], v); break
" > urls.txt
cat urls.txt | xargs -P 8 -n 2 sh -c '[ -s texts/$0.txt ] || curl -sL -m 120 -o texts/$0.txt "$1"'
echo "texts: $(ls texts | wc -l)"

# 4. 分析难度, 生成书单
python3 "$ROOT/tools/build_recommendations.py" --lang en candidates.json efllex.tsv texts "$ROOT/VReading/Resources/Data/recommend_en.json" 18 | grep -v analyzed
