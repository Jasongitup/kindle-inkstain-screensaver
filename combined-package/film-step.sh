#!/bin/sh
# 在渲染脚本的完整环境中逐步测试
# sh /mnt/us/reading-time/bin/film-step.sh

BASE="/mnt/us/reading-time"
FBINK="/var/local/kmc/bin/fbink"
RFONT="$BASE/fonts/NotoSansCJKsc-Regular.otf"
DATA="$BASE/reading-time.tsv"
LOG="$BASE/film-step.log"

# 和渲染脚本完全相同的初始化
exec >> "$LOG" 2>&1

W=1860; H=2480

echo "$(date): === film step test (with exec redirect) ==="

# 步骤 0: 检查数据
echo "$(date): checking data file: $DATA"
if [ -f "$DATA" ]; then
    echo "$(date): data file exists, lines=$(wc -l < "$DATA")"
else
    echo "$(date): ERROR - data file not found!"
fi

# 步骤 1: 测试 awk（在 exec 重定向环境下）
echo "$(date): test awk"
test_val=$(awk -F '\t' 'NR>1{sum+=$3}END{print sum+0}' "$DATA")
echo "$(date): awk total_seconds=$test_val"

# 步骤 2: 测试 date
echo "$(date): test date"
test_date=$(date +%Y-%m-%d)
echo "$(date): date=$test_date"

# 步骤 3: 清屏
echo "$(date): clear screen"
"$FBINK" -q -c -W GC16 -f
echo "$(date): clear rc=$?"
sleep 1

# 步骤 4: 画矩形
echo "$(date): draw rect"
"$FBINK" -q -b -B WHITE -k "top=100,left=100,width=800,height=600" 2>/dev/null
echo "$(date): rect rc=$?"
sleep 1

# 步骤 5: 画文字（简单测试）
echo "$(date): draw text 'test' px=28"
"$FBINK" -q -b -t "regular=$RFONT,bold=$RFONT,px=28,top=200,left=100,right=100" "test" 2>/dev/null
echo "$(date): text rc=$?"
sleep 1

# 步骤 6: 画中文文字
echo "$(date): draw chinese '测试' px=28"
"$FBINK" -q -b -t "regular=$RFONT,bold=$RFONT,px=28,top=300,left=100,right=100" "测试" 2>/dev/null
echo "$(date): chinese rc=$?"
sleep 1

# 步骤 7: 画带 style 的文字
echo "$(date): draw bold 'bold' px=28 style=BOLD"
"$FBINK" -q -b -t "regular=$RFONT,bold=$RFONT,px=28,top=400,left=100,right=100,style=BOLD" "bold" 2>/dev/null
echo "$(date): bold rc=$?"
sleep 1

# 步骤 8: 刷新
echo "$(date): refresh"
"$FBINK" -q -f -W GC16 2>/dev/null
echo "$(date): refresh rc=$?"

echo "$(date): === done ==="
