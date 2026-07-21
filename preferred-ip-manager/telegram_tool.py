#!/home/jason/miniconda3/bin/python3
import os
import argparse
import asyncio
import time
import logging
from telethon import TelegramClient, utils
from telethon.network.mtprotosender import MTProtoSender
from telethon.tl.functions.upload import GetFileRequest
from telethon.tl.types import MessageMediaDocument, MessageMediaPhoto
from telethon.errors import AuthKeyNotFound

# --- API 配置 ---
# 请设置环境变量 TG_API_ID 和 TG_API_HASH
API_ID = os.getenv('TG_API_ID')
API_HASH = os.getenv('TG_API_HASH')
SESSION_NAME = '/home/jason/user_data/config/telegram/my_tg_session'

# 检查配置的函数
def check_config():
    if not API_ID or not API_HASH:
        print("\n错误: 未检测到 API 配置！")
        print("请先设置环境变量:")
        print("  export TG_API_ID='您的_API_ID'")
        print("  export TG_API_HASH='您的_API_HASH'")
        print("\n或者在运行命令前指定:")
        print("  TG_API_ID=xxx TG_API_HASH=yyy python telegram_tool.py list")
        return False
    return True

# 阈值与并发配置
BIG_FILE_THRESHOLD = 200 * 1024 * 1024
FILE_CONCURRENCY = 3  # 限制同时下载的文件数，避免连接重置

class DownloadProgress:
    def __init__(self, filename, total_tasks=1):
        self.filename = filename
        self.start_time = time.time()
        self.last_update_time = self.start_time
        self.last_update_bytes = 0
        self.total_tasks = total_tasks
        self.call_count = 0 
        self.instant_speed = 0
    def callback(self, current, total):
        self.show_progress(current, total)

    def show_progress(self, current, total):
        self.call_count += 1
        now = time.time()
        
        # 确保关键节点（开始、结束）总是显示
        is_important = (current >= total or current == 0 or self.call_count <= 1)
        
        # 频率控制：强制 1 秒左右刷新一次，避免控制台由于高频打印而卡顿
        if not is_important and now - self.last_update_time < 1.0:
            return
        
        # 计算即时速度 (当前瞬时速度)
        interval = now - self.last_update_time
        if interval > 0:
            # 如果是第一次或者刚恢复，直接使用 current 计算是不准的（因为包含历史进度）
            # 我们只计算自上次更新以来新下载的字节数
            if self.last_update_bytes > 0:
                # 只有在 current 确实增加了的情况下才更新速度，避免断连重试时速度显示为 0
                new_bytes = current - self.last_update_bytes
                if new_bytes >= 0:
                    self.instant_speed = new_bytes / interval
            
        self.last_update_time = now
        self.last_update_bytes = current
        
        percentage = current * 100 / total if total > 0 else 0
        speed_str = self.format_size(self.instant_speed) + "/s"
        current_str = self.format_size(current)
        total_str = self.format_size(total)
        
        if self.total_tasks == 1:
            # 单文件模式：使用 \r 实现原地刷新
            print(f"\r{percentage:5.1f}% | {current_str:>9} / {total_str:<9} | {speed_str:>10} | {self.filename[:30]}", end="", flush=True)
            if current >= total: print()
        else:
            # 并发模式：打印新行
            print(f"[{percentage:5.1f}%] {speed_str:>10} | {self.filename[:30]}")

    @staticmethod
    def format_size(size):
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size < 1024:
                return f"{size:.2f}{unit}"
            size /= 1024
        return f"{size:.2f}TB"

async def parallel_download(client, message, save_path, progress, concurrency=4, chunk_size=512*1024):
    """底层 MTProtoSender 并发下载实现 (FastTelethon 原理，极其稳定且极速)"""
    file_size = message.file.size
    # 确保 chunk_size 是 4096 (4KB) 的倍数，以满足大文件下载的强制对齐要求
    chunk_size = (chunk_size // 4096) * 4096 or 4096
    
    dc_id, location = utils.get_input_location(message.media)
    print(f"  [调试] 并发下载初始化: 获取媒体位置成功 (DC: {dc_id})")
    
    # 1. 确保授权已导出到目标 DC
    print(f"  [调试] 正在请求目标 DC 的授权...")
    try:
        # 使用 wait_for 替代 asyncio.timeout 以确保在 python 3.10+ 的兼容性，防止授权死锁
        exported = await asyncio.wait_for(client._borrow_exported_sender(dc_id), timeout=15)
        auth_key = exported.auth_key
        await client._return_exported_sender(exported)
        print(f"  [调试] 目标 DC 授权获取成功")
    except asyncio.TimeoutError:
        print(f"  [调试] 获取 DC 授权超时，可能存在网络阻塞或内部死锁")
        raise Exception("DC 授权获取超时")
    except Exception as e:
        print(f"  [调试] 获取 DC 授权失败: {e}")
        raise e
    
    dc = await client._get_dc(dc_id)
    print(f"  [调试] 获取 DC 网络配置成功: {dc.ip_address}:{dc.port}")
        
    senders = []
    f = None
    try:
        # 2. 创建连接池
        print(f"  [调试] 正在建立 {concurrency} 个并发连接通道...")
        for i in range(concurrency):
            sender = MTProtoSender(auth_key, loggers=client._log)
            # 使用较短的超时时间，避免长时间挂起
            connection = client._connection(dc.ip_address, dc.port, dc.id, loggers=client._log, proxy=client._proxy)
            await asyncio.wait_for(sender.connect(connection), timeout=10)
            senders.append(sender)
            print(f"  [调试] 通道 {i+1} 建立成功")
            
        # 3. 预分配文件或恢复进度
        state_file = f"{save_path}.state"
        downloaded_chunks = set()
        if os.path.exists(state_file):
            try:
                with open(state_file, 'r') as sf:
                    for line in sf:
                        if line.strip():
                            downloaded_chunks.add(int(line.strip()))
                print(f"  [调试] 发现历史下载进度，已恢复 {len(downloaded_chunks)} 个数据块")
            except Exception as e:
                print(f"  [调试] 读取进度文件失败: {e}")
                
        if not os.path.exists(save_path):
            print(f"  [调试] 正在初始化本地文件 (预分配空间)...")
            with open(save_path, 'wb') as tmp_f:
                tmp_f.truncate(file_size)
            
        f = open(save_path, 'r+b')
        downloaded_bytes = 0
        lock = asyncio.Lock()
        
        print(f"  [调试] 任务分块就绪，工作协程启动...")
        queue = asyncio.Queue()
        for offset in range(0, file_size, chunk_size):
            limit = min(chunk_size, file_size - offset)
            if offset in downloaded_chunks:
                downloaded_bytes += limit
                continue
            queue.put_nowait((offset, limit))
            
        progress.show_progress(downloaded_bytes, file_size)
            
        async def worker_task(sender, worker_id):
            nonlocal downloaded_bytes
            while not queue.empty():
                try:
                    offset, limit = queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                    
                success = False
                for attempt in range(10): # 增加重试次数，提高容错率
                    try:
                        # 增加一个小延迟，降低服务端压力
                        await asyncio.sleep(0.05 * worker_id)
                        # Telegram 要求 limit 必须是 1024 的倍数，针对大文件建议 4096 (4KB) 对齐以提高兼容性
                        alignment = 4096
                        request_limit = (limit + (alignment - 1)) // alignment * alignment
                        # 确保请求不会超过 Telegram 允许的最大 512KB 限制
                        request_limit = min(request_limit, 512 * 1024)
                        
                        req = GetFileRequest(location, offset=offset, limit=request_limit)
                        # 将超时大幅增加到 120 秒，以支持 512KB 大分块在慢速网络下的传输
                        try:
                            # 核心逻辑：如果分块正好是文件末尾且不对齐，采用“尾部对齐补丁”算法
                            if offset + limit == file_size and limit % 1024 != 0:
                                # 向前寻找最近的一个 4KB 对齐偏移量，请求文件末尾的最后 4KB
                                patch_offset = max(0, (file_size - 4096) // 4096 * 4096)
                                patch_limit = 4096
                                req = GetFileRequest(location, offset=patch_offset, limit=patch_limit)
                                result = await asyncio.wait_for(sender.send(req), timeout=120)
                                # 计算我们需要的部分在补丁块中的起始位置
                                start_in_patch = offset - patch_offset
                                chunk_data = result.bytes[start_in_patch:start_in_patch + limit]
                            else:
                                req = GetFileRequest(location, offset=offset, limit=request_limit)
                                result = await asyncio.wait_for(sender.send(req), timeout=120)
                                # 只取我们需要的部分，多出来的凑整字节丢弃
                                chunk_data = result.bytes[:limit]
                        except Exception as e:
                            if "limit" in str(e).lower():
                                # 如果对齐请求被拒绝 (如越界)，尝试使用原始精确 limit 再次请求
                                req = GetFileRequest(location, offset=offset, limit=limit)
                                result = await asyncio.wait_for(sender.send(req), timeout=120)
                                chunk_data = result.bytes
                            else:
                                raise e
                        if not chunk_data:
                            raise Exception("收到空数据块")
                            
                        async with lock:
                            f.seek(offset)
                            f.write(chunk_data)
                            downloaded_bytes += len(chunk_data)
                            with open(state_file, 'a') as sf:
                                sf.write(f"{offset}\n")
                            progress.show_progress(downloaded_bytes, file_size)
                            
                        success = True
                        break
                    except Exception as e:
                        # 出现异常时采用指数退避策略
                        wait_time = min(2 ** attempt, 10)
                        print(f"  [调试] 分块 {offset} 尝试 {attempt+1} 失败: {e}")
                        
                        if "closed the connection" in str(e) or isinstance(e, asyncio.TimeoutError):
                            # 连接被关或超时，尝试彻底重连
                            try:
                                await sender.disconnect()
                                await asyncio.sleep(wait_time)
                                await asyncio.wait_for(sender.connect(client._connection(dc.ip_address, dc.port, dc.id, loggers=client._log, proxy=client._proxy)), timeout=15)
                            except:
                                pass
                        else:
                            await asyncio.sleep(wait_time)
                        
                if not success:
                    raise Exception(f"分块 {offset} 失败")

        tasks = [asyncio.create_task(worker_task(s, i)) for i, s in enumerate(senders)]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
        
        for t in pending: t.cancel()
        if pending: await asyncio.gather(*pending, return_exceptions=True)
            
        for t in done:
            if not t.cancelled() and t.exception():
                raise t.exception()
                
        # 下载完成，删除状态文件
        if os.path.exists(state_file):
            os.remove(state_file)
                
    finally:
        if f: f.close()
        for s in senders:
            try:
                await s.disconnect()
            except:
                pass

async def download_task(client, message, output_path, semaphore, task_id, total_tasks, use_parallel=True, chunk_size=512*1024, concurrency=4):
    """单个文件下载任务调度与重试"""
    async with semaphore:
        _, file_name = await get_media_info(message)
        # 清理文件名非法字符，防止路径错误导致连接重置
        file_name = "".join([c for c in file_name if c not in '/\\:*?"<>|']).strip()
        
        save_file = os.path.join(output_path, file_name)
        state_file = f"{save_file}.state"
        file_size = message.file.size or 0
        
        if os.path.exists(save_file):
            if not os.path.exists(state_file):
                if os.path.getsize(save_file) == file_size:
                    print(f"[{task_id}/{total_tasks}] 文件已存在且完整，跳过: {file_name}")
                    return True
                else:
                    save_file = os.path.join(output_path, f"{message.id}_{file_name}")
            else:
                pass # 有 state 文件，准备断点续传

        print(f"[{task_id}/{total_tasks}] 准备下载: {file_name}")
        
        for attempt in range(2):
            try:
                progress = DownloadProgress(file_name, total_tasks=total_tasks)
                if file_size > BIG_FILE_THRESHOLD:
                    # 并发模式用用户指定的线程数，标准模式用 1 线程
                    actual_concurrency = concurrency if use_parallel else 1
                    try:
                        await parallel_download(client, message, save_file, progress, concurrency=actual_concurrency, chunk_size=chunk_size)
                    except Exception as e:
                        print(f"\n[{task_id}] 下载遇到困难，尝试回退到单通道安全模式继续断点续传... ({e})")
                        await parallel_download(client, message, save_file, progress, concurrency=1, chunk_size=chunk_size)
                else:
                    await client.download_media(message, save_file, progress_callback=progress.callback)
                return True
            except Exception as e:
                if attempt == 0:
                    print(f"\n[{task_id}] 下载中断，正在尝试重连重试... ({e})")
                    await asyncio.sleep(3)
                else:
                    print(f"\n[{task_id}] 下载彻底失败: {file_name} ({e})")
                    return False

async def download_files(client, chat_id, chat_name, limit, output_path, msg_ids=None, file_filter=None, use_parallel=True, chunk_size=512*1024, concurrency=4):
    """主下载调度逻辑"""
    abs_output_path = os.path.abspath(output_path)
    if not os.path.exists(abs_output_path):
        os.makedirs(abs_output_path)

    entity = None
    if chat_id:
        try:
            entity = await client.get_entity(chat_id)
        except Exception as e:
            print(f"错误: 无法获取 ID 为 {chat_id} 的聊天 ({e})")
            return
    elif chat_name:
        print(f"正在搜索包含关键字 '{chat_name}' 的聊天...")
        matches = []
        async for dialog in client.iter_dialogs():
            if chat_name.lower() in dialog.title.lower():
                matches.append(dialog)
        
        if not matches:
            print(f"错误: 未找到包含关键字 '{chat_name}' 的聊天。")
            return
        
        if len(matches) > 1:
            print(f"发现 {len(matches)} 个匹配项，默认选择第一个: '{matches[0].title}'")
        
        entity = matches[0].entity
    else:
        print("错误: 请提供 ID 或名称")
        return

    # 1. 收集消息
    pending_messages = []
    if msg_ids:
        print(f"正在收集指定的资源...")
        msgs = await client.get_messages(entity, ids=msg_ids)
        pending_messages = [m for m in (msgs if isinstance(msgs, list) else [msgs]) if m and m.media]
    else:
        filter_str = f" (过滤: '{file_filter}')" if file_filter else ""
        print(f"正在收集最近匹配的 {limit} 个资源{filter_str}...")
        async for message in client.iter_messages(entity, limit=500):
            if message.media:
                _, file_name = await get_media_info(message)
                if file_filter and file_filter.lower() not in file_name.lower():
                    continue
                pending_messages.append(message)
                if len(pending_messages) >= limit:
                    break

    if not pending_messages:
        print("未发现匹配资源")
        return

    print(f"正在启动并行下载 (最大并发文件数: {FILE_CONCURRENCY})...")
    
    # 2. 调度执行
    sem = asyncio.Semaphore(FILE_CONCURRENCY)
    tasks = []
    for i, msg in enumerate(pending_messages):
        tasks.append(download_task(client, msg, abs_output_path, sem, i+1, len(pending_messages), 
                                 use_parallel=use_parallel, chunk_size=chunk_size, concurrency=concurrency))
    
    results = await asyncio.gather(*tasks)
    success_count = sum(1 for r in results if r)
    
    print(f"\n全部完成！成功下载 {success_count}/{len(pending_messages)} 个文件。")
    print(f"保存路径: {abs_output_path}")

async def list_chats(client):
    """获取并显示最近的对话列表"""
    print("\n正在获取聊天列表...")
    print(f"{'Chat ID':<15} | {'Title'}")
    print("-" * 50)
    async for dialog in client.iter_dialogs(limit=30):
        print(f"{dialog.id:<15} | {dialog.title}")
    print("-" * 50)

async def get_media_info(message):
    """提取消息中的媒体类型和文件名"""
    if not message.media:
        return "Text", message.text.replace('\n', ' ')[:30] if message.text else ""
    
    media_type = "Unknown"
    file_name = "N/A"
    
    if isinstance(message.media, MessageMediaPhoto):
        media_type = "Photo"
        file_name = f"photo_{message.id}.jpg"
    elif isinstance(message.media, MessageMediaDocument):
        media_type = "Document"
        for attr in message.media.document.attributes:
            if hasattr(attr, 'file_name'):
                file_name = attr.file_name
                break
        if file_name == "N/A":
            file_name = f"doc_{message.id}"
            
    return media_type, file_name

async def show_messages(client, chat_id, limit):
    """展示指定聊天的消息和资源列表"""
    try:
        entity = await client.get_entity(chat_id)
    except Exception as e:
        print(f"错误: 无法获取 ID 为 {chat_id} 的聊天 ({e})")
        return

    print(f"\n正在获取 '{entity.title}' 的消息列表 (最近 {limit} 条):")
    print(f"{'ID':<10} | {'Time (UTC)':<19} | {'Type':<10} | {'Content/File'}")
    print("-" * 80)

    async for message in client.iter_messages(entity, limit=limit):
        m_type, m_info = await get_media_info(message)
        time_str = message.date.strftime("%Y-%m-%d %H:%M:%S")
        print(f"{message.id:<10} | {time_str:<19} | {m_type:<10} | {m_info}")
    
    print("-" * 80)

async def main():
    parser = argparse.ArgumentParser(description="Telegram 助手: 列表获取、预览与下载")
    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # List 命令
    subparsers.add_parser("list", help="显示最近的聊天对话列表")

    # Show 命令
    show_parser = subparsers.add_parser("show", help="展示指定聊天的消息和资源列表")
    show_parser.add_argument("--id", type=int, required=True, help="目标聊天的 ID")
    show_parser.add_argument("--limit", "-l", type=int, default=20, help="展示的消息数量 (默认: 20)")

    # Download 命令
    dl_parser = subparsers.add_parser("download", help="下载指定聊天的文件")
    dl_parser.add_argument("--id", type=int, help="目标聊天的 ID")
    dl_parser.add_argument("--name", "-n", type=str, help="目标聊天的完整名称")
    dl_parser.add_argument("--filter", "-f", type=str, help="资源文件名过滤关键字 (不区分大小写)")
    dl_parser.add_argument("--limit", "-l", type=int, default=10, help="下载文件数量限制 (默认: 10)")
    dl_parser.add_argument("--ids", type=int, nargs="+", help="指定要下载的消息 ID 列表")
    dl_parser.add_argument("--output", "-o", type=str, default="./downloads", help="下载保存路径")
    dl_parser.add_argument("--mode", "-m", choices=["parallel", "standard"], default="parallel", help="大文件下载模式: parallel (并行, 默认) 或 standard (标准)")
    dl_parser.add_argument("--chunk-size", type=int, default=512, help="分块大小 (KB, 默认: 512)")
    dl_parser.add_argument("--concurrency", "-c", type=int, default=4, help="并发线程数 (默认: 4)")

    args = parser.parse_args()

    if not check_config():
        return

    # 初始化 Client 时增加自动重连和无限重试
    client = TelegramClient(
        SESSION_NAME, 
        API_ID, 
        API_HASH,
        connection_retries=None, # 无限重试连接
        retry_delay=2            # 重试间隔
    )
    
    async with client:
        if args.command == "list":
            await list_chats(client)
        elif args.command == "show":
            await show_messages(client, args.id, args.limit)
        elif args.command == "download":
            use_parallel = (args.mode == "parallel")
            chunk_size = args.chunk_size * 1024
            await download_files(client, args.id, args.name, args.limit, args.output, args.ids, args.filter, 
                               use_parallel=use_parallel, chunk_size=chunk_size, concurrency=args.concurrency)
        else:
            parser.print_help()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n用户中止操作")
