#!/usr/bin/env python3
"""
mcp_server.py - MCP HTTP 接口

提供 RESTful API, 允许 OpenClaw 或其他系统:
  - 触发订阅更新和节点切换
  - 查询当前状态
  - 手动切换代理节点

端点:
  POST /mcp/update          - 触发订阅更新 (异步执行)
  GET  /mcp/status          - 查询更新状态和当前节点信息
  POST /mcp/switch          - 切换代理节点
  GET  /mcp/nodes           - 列出所有可用节点
  GET  /mcp/health          - 健康检查

启动:
  python3 scripts/mcp_server.py
  # 或通过 uvicorn:
  uvicorn scripts.mcp_server:app --host 0.0.0.0 --port 8900
"""
import asyncio
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel

# ===== 路径配置 =====
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
UPDATE_SCRIPT = SCRIPT_DIR / "update_sub.sh"

# ===== 环境变量 =====
API_PORT = int(os.getenv("MIHOMO_API_PORT", "9090"))
MIHOMO_API_BASE = f"http://127.0.0.1:{API_PORT}"

# ===== FastAPI 应用 =====
app = FastAPI(
    title="Auto-Mihomo MCP Server",
    description="MCP HTTP 接口 - 代理订阅管理与节点切换",
    version="1.0.0",
)

# ===== 全局状态 =====
_state = {
    "update_running": False,
    "last_update_time": None,
    "last_update_result": None,
    "update_count": 0,
}


# ===== 响应模型 =====
class UpdateResponse(BaseModel):
    status: str
    message: str
    timestamp: str


class StatusResponse(BaseModel):
    update_running: bool
    last_update_time: str | None
    last_update_result: dict | None
    update_count: int


class SwitchRequest(BaseModel):
    node: str
    group: str = "Proxy"


class SwitchResponse(BaseModel):
    status: str
    message: str
    node: str
    group: str


class NodeInfo(BaseModel):
    name: str
    type: str
    alive: bool
    delay: int


# ===== 后台更新任务 =====
async def _run_update():
    """在后台执行 update_sub.sh"""
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash",
            str(UPDATE_SCRIPT),
            "--skip-proxy",  # MCP 调用时跳过系统代理设置
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(PROJECT_DIR),
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=180)

        _state["last_update_result"] = {
            "success": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": stdout.decode("utf-8", errors="replace")[-3000:],
            "stderr": stderr.decode("utf-8", errors="replace")[-3000:],
        }
    except asyncio.TimeoutError:
        _state["last_update_result"] = {
            "success": False,
            "error": "更新超时 (180s)",
        }
    except Exception as e:
        _state["last_update_result"] = {
            "success": False,
            "error": str(e),
        }
    finally:
        _state["update_running"] = False
        _state["last_update_time"] = datetime.now().isoformat()
        _state["update_count"] += 1


# ===== API 端点 =====


@app.post("/mcp/update", response_model=UpdateResponse)
async def trigger_update():
    """
    触发订阅更新

    异步执行 update_sub.sh, 包括:
    下载订阅 → 测试节点 → 生成配置 → 重启 Mihomo
    """
    if _state["update_running"]:
        return UpdateResponse(
            status="busy",
            message="更新正在进行中, 请稍后再试",
            timestamp=datetime.now().isoformat(),
        )

    _state["update_running"] = True
    asyncio.create_task(_run_update())

    return UpdateResponse(
        status="accepted",
        message="更新任务已提交, 请通过 /mcp/status 查询进度",
        timestamp=datetime.now().isoformat(),
    )


@app.get("/mcp/status", response_model=StatusResponse)
async def get_status():
    """查询更新状态和最近一次更新结果"""
    return StatusResponse(
        update_running=_state["update_running"],
        last_update_time=_state["last_update_time"],
        last_update_result=_state["last_update_result"],
        update_count=_state["update_count"],
    )


@app.post("/mcp/switch", response_model=SwitchResponse)
async def switch_node(req: SwitchRequest):
    """
    切换代理节点

    通过 Mihomo RESTful API 切换指定代理组的活动节点
    """
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            # 验证代理组存在
            resp = await client.get(f"{MIHOMO_API_BASE}/proxies/{req.group}")
            if resp.status_code != 200:
                raise HTTPException(
                    status_code=404,
                    detail=f"代理组 '{req.group}' 不存在",
                )

            group_data = resp.json()
            available = [p for p in group_data.get("all", [])]

            if req.node not in available:
                raise HTTPException(
                    status_code=400,
                    detail=f"节点 '{req.node}' 不在代理组 '{req.group}' 中, "
                    f"可用节点: {available[:20]}...",
                )

            # 执行切换
            resp = await client.put(
                f"{MIHOMO_API_BASE}/proxies/{req.group}",
                json={"name": req.node},
            )

            if resp.status_code == 204:
                return SwitchResponse(
                    status="ok",
                    message=f"已切换到 {req.node}",
                    node=req.node,
                    group=req.group,
                )
            else:
                raise HTTPException(
                    status_code=500,
                    detail=f"切换失败: HTTP {resp.status_code} - {resp.text}",
                )

    except httpx.ConnectError:
        raise HTTPException(
            status_code=502,
            detail="无法连接 Mihomo API, 请确认 Mihomo 正在运行",
        )


@app.get("/mcp/nodes")
async def list_nodes(
    group: str = Query(default="Proxy", description="代理组名称"),
):
    """列出指定代理组中的所有节点及其延迟信息"""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{MIHOMO_API_BASE}/proxies/{group}")
            if resp.status_code != 200:
                raise HTTPException(
                    status_code=404,
                    detail=f"代理组 '{group}' 不存在",
                )

            group_data = resp.json()
            all_names = group_data.get("all", [])
            now_node = group_data.get("now", "")

            # 获取各节点详情
            nodes = []
            for name in all_names:
                node_resp = await client.get(
                    f"{MIHOMO_API_BASE}/proxies/{name}"
                )
                if node_resp.status_code == 200:
                    nd = node_resp.json()
                    history = nd.get("history", [])
                    last_delay = history[-1].get("delay", 0) if history else 0
                    nodes.append(
                        {
                            "name": nd.get("name", name),
                            "type": nd.get("type", "unknown"),
                            "alive": nd.get("alive", False),
                            "delay": last_delay,
                            "current": name == now_node,
                        }
                    )

            return {
                "group": group,
                "current": now_node,
                "total": len(nodes),
                "nodes": nodes,
            }

    except httpx.ConnectError:
        raise HTTPException(
            status_code=502,
            detail="无法连接 Mihomo API, 请确认 Mihomo 正在运行",
        )


@app.get("/mcp/health")
async def health_check():
    """健康检查 - 验证 MCP 服务和 Mihomo 是否正常"""
    mihomo_ok = False
    mihomo_version = None

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{MIHOMO_API_BASE}/version")
            if resp.status_code == 200:
                mihomo_ok = True
                mihomo_version = resp.json().get("version", "unknown")
    except Exception:
        pass

    return {
        "mcp_server": "ok",
        "mihomo": "ok" if mihomo_ok else "unreachable",
        "mihomo_version": mihomo_version,
        "timestamp": datetime.now().isoformat(),
    }


# ===== 启动入口 =====
if __name__ == "__main__":
    import uvicorn

    # 加载 .env
    env_file = PROJECT_DIR / ".env"
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    os.environ.setdefault(key.strip(), value.strip())

    port = int(os.getenv("MCP_SERVER_PORT", "8900"))
    print(f"MCP Server 启动于 http://0.0.0.0:{port}")
    print(f"Mihomo API: {MIHOMO_API_BASE}")
    print(f"API 文档: http://0.0.0.0:{port}/docs")

    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
