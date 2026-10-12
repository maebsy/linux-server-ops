"""테스트용 가짜 agent 앱: 지정한 포트를 LISTEN 하고 종료 신호까지 대기한다.

monitor.sh 가 실제 제공 앱과 같은 방식(실행 파일 이름 + 포트)으로 찾을 수 있도록
테스트에서는 이 파일을 agent_app.py 라는 이름으로 복사해 실행한다.
"""

import signal
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 15034
listen = "--no-listen" not in sys.argv
sock = None
if listen:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    sock.listen(5)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
print("Agent READY (fake) port={} listen={}".format(port, listen), flush=True)
while True:
    time.sleep(1)
