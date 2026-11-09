"""테스트용 가짜 agent 앱: 지정한 포트를 LISTEN 하고 종료 신호까지 대기한다.

monitor.sh 가 실제 제공 앱과 같은 방식(실행 파일 이름 + 포트)으로 찾을 수 있도록
테스트에서는 이 파일을 agent_app.py 라는 이름으로 복사해 실행한다.
"""

import signal
import socket
import sys
import threading
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else 15034
listen = "--no-listen" not in sys.argv
bind = "0.0.0.0"  # --bind ADDR 로 바인딩 주소를 바꾼다 (루프백만 바인딩 테스트용)
if "--bind" in sys.argv:
    bind = sys.argv[sys.argv.index("--bind") + 1]
sock = None
if listen:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((bind, port))
    sock.listen(5)
if "--busy" in sys.argv:  # CPU 를 계속 쓰는 상태 (프로세스 순간 CPU 측정 테스트용)
    def burn():
        while True:
            pass
    threading.Thread(target=burn, daemon=True).start()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
print("Agent READY (fake) port={} bind={} listen={}".format(port, bind, listen), flush=True)
while True:
    time.sleep(1)
