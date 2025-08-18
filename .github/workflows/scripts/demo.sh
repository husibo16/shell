#!/usr/bin/env bash
# Demo script - fixed version with safe practices

# 使用双引号防止单词分割
echo "Hello ${NAME}"

# 用 * 遍历文件，而不是 $(ls)
for f in *; do
  # 判断是否为文件再输出
  if [ -f "$f" ]; then
    echo "$f"
  fi
done
