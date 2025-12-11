PRD (Product Requirements Document)
프로젝트 개요
이름: Penput
목적: 모바일 브라우저를 데스크탑 마우스 리모컨으로 사용
핵심 가치: 최소 지연, 간단한 사용성

1. 기능 명세
1.1 연결 흐름
```
1. 사용자가 데스크탑에서 Rust 바이너리 실행
2. CLI에 표시된 IP 주소를 모바일 브라우저에 입력 (예: http://192.168.0.10:8080)
3. HTML 페이지 로드 → 자동으로 /ws 라우트로 WebSocket 연결 시도
4. 백엔드 CLI에 "연결 요청: [IP주소]" 표시
5. 사용자가 CLI에서 'y' 입력으로 승인
6. WebSocket 연결 완료 → 모바일 브라우저 자동 전체화면
```

1.2 마우스 제어
입력 방식: 절대 좌표 매핑

모바일 화면 전체가 터치패드
터치 위치 비율 = 데스크탑 스크린 위치 비율
예: 모바일 화면 50%, 50% 터치 → 데스크탑 화면 중앙

동작 모드:

터치 시작: 해당 위치로 마우스 이동
터치 유지 + 이동: 마우스 계속 이동
터치 종료: 마우스 정지

지원 안 함: 클릭, 드래그, 스크롤, 키보드
1.3 사용자 인터페이스
모바일 브라우저 (전체화면):
```
┌─────────────────────────┐
│  [❌ Exit]             │ ← 작은 버튼 (우측 상단)
│                         │
│                         │
│    전체 터치 영역       │
│    (마우스 패드)        │
│                         │
│                         │
│  ● 터치 상태 표시       │ ← 작은 인디케이터
└─────────────────────────┘
```
터치 상태 표시:

터치 중: 작은 점/원 표시 (예: 빨간 점)
터치 안 함: 표시 없음

Exit 버튼:

우측 상단 작은 버튼 (30x30px 정도)
클릭 시 전체화면 종료 + WebSocket 연결 해제

1.4 연결 제한

단일 클라이언트만 연결 가능
이미 연결된 상태에서 새 연결 시도 시:

새 클라이언트에게 "Already connected" 메시지 후 연결 거부
CLI에 "연결 거부: 이미 연결된 클라이언트 있음" 표시




2. 기술 스펙
2.1 프로토콜
WebSocket 메시지 포맷 (Binary):
```
Client → Server (초기 handshake, JSON):
{
  "type": "init",
  "width": 1080,   // 모바일 화면 너비
  "height": 2400   // 모바일 화면 높이
}

Client → Server (마우스 이동, Binary):
[x: u16 (2bytes)][y: u16 (2bytes)]
// 총 4 bytes

Server → Client (상태 응답, Text):
"connected" | "rejected" | "error"
```
좌표 계산 (백엔드):
```
// 모바일: (touch_x, touch_y), 화면 크기: (client_width, client_height)
// 데스크탑: 화면 크기: (screen_width, screen_height)

let ratio_x = touch_x / client_width;
let ratio_y = touch_y / client_height;

let screen_x = (ratio_x * screen_width) as i32;
let screen_y = (ratio_y * screen_height) as i32;

enigo.move_mouse(screen_x, screen_y, Absolute);
```

### 2.2 성능 목표
- **지연시간**: < 30ms (로컬 WiFi)
- **전송 빈도**: 60fps (16.6ms 간격, requestAnimationFrame)
- **이벤트 처리**: 쓰로틀링 적용

### 2.3 아키텍처

**백엔드 (Rust)**:
```
src/
├── main.rs              # CLI 진입점, 서버 시작
├── http.rs              # Axum HTTP 서버 (정적 파일)
├── websocket.rs         # WebSocket 핸들러
├── mouse.rs             # enigo 래퍼, 좌표 계산
├── connection.rs        # 연결 승인/거부 로직
└── static/
    ├── index.html       # 임베드된 정적 파일
    ├── app.js
    └── style.css
```
프론트엔드 (Vanilla JS):
```
// 핵심 흐름
1. WebSocket 연결
2. 화면 크기 전송 (init)
3. Fullscreen API 호출
4. touchstart/touchmove 이벤트 → RAF → Binary 전송
5. touchend 이벤트 → 상태 업데이트
```


3. CLI 명세
3.1 실행
```
# 기본 실행
./penput

# 포트 지정
./penput --port 8080

# WebSocket 포트 지정
./penput --ws-port 9001

# 자동 승인 모드 (테스트용)
./penput --auto-approve
```

### 3.2 출력 예시
```
🖱️  Penput
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Server running at:
  HTTP: http://192.168.0.10:8080
  WebSocket: ws://192.168.0.10:9001/ws

Open this URL on your mobile browser.
Press Ctrl+C to stop.

[14:23:15] 📱 Connection request from 192.168.0.25
           Approve? (y/n): y
[14:23:16] ✓ Client connected: 192.168.0.25
[14:23:16] 📡 Screen size: 1080x2400
[14:23:45] ✗ Client disconnected
```
3.3 연결 승인 흐름
```
// CLI에서 대기
loop {
    if let Some(pending_client) = connection_queue.pop() {
        println!("Connection request from {}", pending_client.ip);
        print!("Approve? (y/n): ");
        
        let mut input = String::new();
        stdin().read_line(&mut input)?;
        
        if input.trim() == "y" {
            approve_connection(pending_client);
        } else {
            reject_connection(pending_client);
        }
    }
}
```
4. 배포 스펙
4.1 패키징

단일 실행 파일: penput (또는 penput.exe)
정적 파일 임베드: include_str!() 사용
크기 목표: < 5MB (릴리스 빌드)

4.2 플랫폼 지원

우선순위: Windows 10/11
추후 고려: macOS, Linux

4.3 빌드 설정
```toml
[profile.release]
opt-level = 3
lto = true
codegen-units = 1
strip = true
```
5. 보안 명세
5.1 네트워크

로컬 네트워크만: 0.0.0.0으로 바인드하되 방화벽 권장
HTTPS 없음: 로컬 환경이므로 HTTP 사용
인증 없음: CLI 승인이 인증 역할

5.2 입력 검증
```rs
// 좌표 범위 검증
if x > screen_width || y > screen_height {
    return Err("Invalid coordinates");
}

// Rate limiting
if events_per_second > 120 {
    drop_event();
}
```

6. MVP 체크리스트
Phase 1 (필수)

 HTTP 서버로 HTML 서빙
 WebSocket 연결 (/ws)
 초기 화면 크기 전송 (init)
 Binary 프로토콜 (x, y 좌표)
 절대 좌표 매핑
 마우스 이동 (enigo)
 CLI 연결 승인/거부
 단일 클라이언트 제한
 전체화면 모드
 Exit 버튼
 터치 상태 표시
 정적 파일 임베드

Phase 2 (개선)

 자동 IP 발견 (mDNS)
 민감도 조절 (CLI flag)
 연결 통계 (지연시간, 전송률)
 로그 파일 저장