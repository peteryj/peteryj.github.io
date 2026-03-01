---
layout: post
title: OpenClaw Gateway 在 AIDLux 上的部署实践与坑点记录
date: 2026-03-01 15:00
comments: true
author: Peter.Y
categories: AI aidlux openclaw 
---

* content
{:toc}

## 背景

OpenClaw 是一个强大的 AI 助手平台，但在 AIDLux（AI 设备专用 Linux 发行版）上部署时会遇到一些特殊问题。本文记录了我在 AIDLux 上部署 OpenClaw Gateway 时遇到的坑和解决方案。

## 环境信息

- **系统**: AIDLux (Arm Linux)
- **架构**: ARM64
- **目标**: 部署 OpenClaw Gateway + Node.js 服务
- **挑战**: AIDLux 资源受限，无 systemd，Node.js 权限受限

## 问题一：Node.js 获取 IP 地址的权限问题

### 现象

运行 Node.js 服务时，使用 `os.networkInterfaces()` 或类似方法获取 IP 地址时失败，表现为服务无法启动。

```javascript
// 报错示例
os.networkInterfaces() // Error: EACCES: permission denied
```

### 原因分析

AIDLux 为了安全考虑，限制了普通用户对网络接口信息的访问权限。这是出于以下考虑：

1. 防止恶意程序窃取网络设备信息
2. 减少攻击面
3. 符合最小权限原则

### 解决方案：Hijack 方法

通过 hijack Node.js 的网络接口调用，绕过权限限制。核心思路是修改 Node.js 的行为，让它不依赖底层系统调用，而是返回预配置的值。

#### 方案 A：环境变量注入

```bash
export NODE_HOST="0.0.0.0"
export NODE_PORT="7890"
```

然后在代码中优先读取环境变量：

```javascript
const HOST = process.env.NODE_HOST || 
             Object.values(os.networkInterfaces())
                   .flat()
                   .find(i => !i.internal)?.address || '0.0.0.0';
```

#### 方案 B：Module Hijack（推荐）

创建一个包装模块，覆盖 Node.js 原生的 `os` 模块行为：

```javascript
// network-hijack.js
const Module = require('module');
const originalNetworkInterfaces = Module.prototype.require;

Module.prototype.require = function(id) {
  const module = originalNetworkInterfaces.apply(this, arguments);
  
  if (id === 'os') {
    return {
      ...module,
      networkInterfaces: () => ({
        eth0: [{
          address: '192.168.1.100',  // 替换为你的实际 IP
          netmask: '255.255.255.0',
          family: 'IPv4',
          mac: '00:00:00:00:00:00',
          internal: false
        }]
      })
    };
  }
  
  return module;
};
```

加载方式：

```javascript
require('./network-hijack');
const app = require('./app');
```

#### 方案 C：Preload Hook

更优雅的方式是使用 `--loader` 或 `NODE_OPTIONS` 注入 preload：

```bash
NODE_OPTIONS="--require ./network-hijack.js" node app.js
```

## 问题二：AIDLux 下没有 systemd，无法自动启动 OpenClaw Gateway

### 现象

在常规 Linux 系统上，我们使用：

```bash
systemctl start openclaw-gateway
# 或
openclaw gateway start
```

但在 AIDLux 上执行这些命令会提示：

```
Failed to connect to system bus: No such file or directory
Command not found: systemctl
```

### 原因分析

AIDLux 是基于精简需求设计的系统，去除了 systemd 以节省资源。这意味着：

1. 没有 `/lib/systemd/systemd`
2. 没有 `systemctl` 命令
3. 没有 init.d 目录
4. 开机不会自动执行自定义脚本

### 解决方案：Keep Alive 脚本

编写一个 `keep.sh` 脚本，实现进程守护功能。

#### 基础版本

```bash
#!/bin/bash
# keep.sh - Keep OpenClaw Gateway running

GATEWAY_PID_FILE="/tmp/openclaw-gateway.pid"
LOG_DIR="/var/log/openclaw"
WORKDIR="/home/aidlux/.openclaw/workspace"

mkdir -p "$LOG_DIR"

start_gateway() {
    echo "Starting OpenClaw Gateway..."
    
    cd "$WORKDIR"
    
    nohup node gateway.js > "$LOG_DIR/gateway.out" 2>&1 &
    local PID=$!
    
    echo $PID > "$GATEWAY_PID_FILE"
    
    echo "Gateway started with PID: $PID"
}

check_process() {
    if [ -f "$GATEWAY_PID_FILE" ]; then
        local PID=$(cat "$GATEWAY_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            return 0  # Process exists
        fi
    fi
    return 1  # Process doesn't exist
}

# Main loop
while true; do
    if check_process; then
        sleep 60  # Check every minute
    else
        echo "$(date): Gateway crashed or not running. Restarting..." >> "$LOG_DIR/gateway.log"
        start_gateway
        sleep 5  # Wait before next check
    fi
    
    sleep 10  # Check interval
done
```

#### 高级版本（带日志轮转和信号处理）

```bash
#!/bin/bash
# keep.sh - Enhanced version with proper signal handling

set -e

GATEWAY_BIN="gateway"
GATEWAY_ARGS="-c config.json"
WORKDIR="/home/aidlux/.openclaw/workspace"
LOG_FILE="$WORKDIR/logs/gateway.log"
ERR_LOG="$WORKDIR/logs/gateway-error.log"
PID_FILE="$WORKDIR/.gateway.pid"
START_COUNT_FILE="$WORKDIR/.gateway.start-count"

LOG_MAX_SIZE=10M
LOG_BACKUPS=3

cleanup() {
    echo "$(date): Received shutdown signal. Stopping gateway..."
    
    if [ -f "$PID_FILE" ]; then
        local PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            kill -TERM $PID 2>/dev/null || true
            sleep 2
            
            # Force kill if still running
            if ps -p $PID > /dev/null 2>&1; then
                kill -KILL $PID 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    exit 0
}

log_rotate() {
    if [ -f "$LOG_FILE" ]; then
        local SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$SIZE" -gt "$LOG_MAX_SIZE" ]; then
            for i in $(seq $((LOG_BACKUPS-1)) -1 1); do
                [ -f "${LOG_FILE}.$i" ] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
        fi
    fi
}

start_gateway() {
    echo "$(date): Starting OpenClaw Gateway..." >> "$LOG_FILE"
    
    cd "$WORKDIR"
    
    node $GATEWAY_BIN $GATEWAY_ARGS >> "$LOG_FILE" 2>> "$ERR_LOG" &
    local PID=$!
    
    echo $PID > "$PID_FILE"
    
    echo "$(date): Gateway started with PID: $PID" >> "$LOG_FILE"
    
    # Reset crash counter
    echo "0" > "$START_COUNT_FILE"
    
    return $PID
}

trap cleanup SIGINT SIGTERM SIGHUP

# Main loop with exponential backoff on crashes
MAX_RESTARTS=10
CRASH_DELAY=10

while true; do
    if [ ! -f "$PID_FILE" ]; then
        PID=$(start_gateway)
        WAIT_TIME=0
    else
        PID=$(cat "$PID_FILE")
        
        if ! ps -p $PID > /dev/null 2>&1; then
            CRASH_DELAY=$((CRASH_DELAY * 2))
            [ $CRASH_DELAY -gt 300 ] && CRASH_DELAY=300  # Cap at 5 minutes
            
            echo "$(date): Process $PID died. Waiting ${CRASH_DELAY}s before restart..." >> "$LOG_FILE"
            
            sleep $CRASH_DELAY
            PID=$(start_gateway)
            CRASH_DELAY=10
        fi
    fi
    
    # Rotate logs daily
    log_rotate
    
    sleep 30
done
```

#### 使用指南

1. **创建脚本并赋予执行权限**：

```bash
cd /home/aidlux/.openclaw/workspace
cat > keep.sh << 'SCRIPT_EOF'
#!/bin/bash
# 在此粘贴上面的脚本内容
SCRIPT_EOF

chmod +x keep.sh
```

2. **后台运行脚本**：

```bash
nohup ./keep.sh > /dev/null 2>&1 &
echo $! > /tmp/keep.pid
```

3. **开机自启动配置**

虽然 AIDLux 没有 systemd，但可以在 `/etc/rc.local` 中添加启动命令：

```bash
#!/bin/sh
# rc.local - Run at boot

sleep 10  # Wait for network to be ready
cd /home/aidlux/.openclaw/workspace
nohup ./keep.sh > /dev/null 2>&1 &
```

或者使用 crontab 的 `@reboot`：

```bash
(crontab -l 2>/dev/null; echo "@reboot cd /home/aidlux/.openclaw/workspace && nohup ./keep.sh > /dev/null 2>&1 &") | crontab -
```

## 完整的部署流程

下面是我最终使用的完整部署步骤：

```bash
#!/bin/bash
# deploy-openclaw.sh - Complete deployment script

set -e

WORKDIR="/home/aidlux/.openclaw/workspace"
CONFIG_PATH="$WORKDIR/config.json"

echo "=== OpenClaw Gateway Deployment Script ==="

# 1. 设置环境变量
export NODE_HOST="0.0.0.0"
export NODE_PORT="7890"

# 2. 安装依赖
echo "Installing dependencies..."
npm install -g openclaw@latest

# 3. 克隆工作区
if [ ! -d "$WORKDIR" ]; then
    echo "Creating workdir..."
    mkdir -p "$WORKDIR"
fi

# 4. 配置节点连接
echo "Configuring node connection..."
openclaw nodes register --token <YOUR_NODE_TOKEN>

# 5. 启动 Gateway
echo "Starting gateway..."
cd "$WORKDIR"
./keep.sh &

echo "Deployment complete!"
echo "You can now access OpenClaw at:"
echo "  URL: http://$(hostname -I | awk '{print $1}'):7890"
```

## 注意事项

### 性能优化建议

1. **内存限制**: AIDLux 通常只有几百 MB 内存，注意设置 Node.js 的 heap 大小
   ```bash
   NODE_OPTIONS="--max-old-space-size=256" node app.js
   ```

2. **日志管理**: 定期清理日志文件，避免磁盘占满
   
3. **网络配置**: 固定 IP 地址，确保服务可访问性

### 常见问题

**Q: Gateway 启动后立即退出？**
- 检查配置文件路径是否正确
- 查看日志文件 `/home/aidlux/.openclaw/workspace/logs/gateway.log`

**Q: 端口被占用怎么办？**
- `netstat -tlnp | grep :7890` 查看占用情况
- 更换端口或在 `config.json` 中指定其他端口

**Q: keep.sh 挂了怎么办？**
- 重启整个 AIDLux 设备
- 手动在 `/etc/rc.local` 添加兜底启动脚本

## 总结

在 AIDLux 上部署 OpenClaw 确实会遇到一些特殊挑战，但通过 hijack 方法和 keepalive 脚本可以很好地解决这些问题。希望这篇文章能帮助同样在嵌入式设备上部署 OpenClaw 的朋友们少走弯路！

**欢迎在评论区交流你的部署经验！** 👇

---

*如果本文对你有帮助，别忘了 Star 我的 GitHub 项目，关注后续更新！*
*GitHub: https://github.com/peteryj/peteryj.github.io*
