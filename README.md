# 서울 경매지도 — 자동 업데이트 앱 셋업 가이드

## 이 저장소가 하는 일

- `scripts/scrape.py`가 경매마당에서 서울 아파트 경매 물건을 긁어와 `data.json`으로 저장
- `.github/workflows/update-data.yml`이 **매일 자동으로** 이 스크립트를 실행하고 결과를 커밋
- `index.html`이 GitHub Pages로 배포되면, 켤 때마다 `data.json`을 불러와서 카카오맵 위에 표시

## 1단계 — GitHub 저장소 만들기

1. github.com 접속 → 로그인 (계정 없으면 가입, 무료)
2. 우측 상단 **+** → **New repository**
3. Repository name: 원하는 이름 (예: `auction-map`)
4. **Public**으로 설정 (GitHub Pages 무료 플랜은 Public 저장소만 지원)
5. Create repository

## 2단계 — 파일 업로드

방금 만든 저장소 페이지에서 **"uploading an existing file"** 링크 클릭 (또는 Add file → Upload files) → 이 대화에서 받은 파일들을 폴더 구조 그대로 드래그해서 업로드

```
auction-map/
├── index.html
├── data.json
├── README.md
├── scripts/
│   └── scrape.py
└── .github/
    └── workflows/
        └── update-data.yml
```

**주의**: 웹 UI로 업로드하면 `.github/workflows/` 같은 하위 폴더 구조를 유지한 채 드래그해야 해요. 폴더째로 드래그하면 자동으로 구조가 유지됩니다. 안 되면 GitHub Desktop 앱을 쓰는 게 더 편해요.

## 3단계 — 카카오 REST API 키 발급 (지오코딩용)

지금 갖고 계신 JavaScript 키와는 별개로, 스크래퍼가 주소를 좌표로 바꾸려면 **REST API 키**가 필요해요.

1. 카카오디벨로퍼스 → 기존 앱("Banana") 들어가기
2. [앱] → [플랫폼 키]에서 **REST API 키** 복사 (JavaScript 키 바로 옆에 있어요)

## 4단계 — GitHub에 REST 키를 비밀값(Secret)으로 등록

1. 저장소 페이지 → **Settings** 탭
2. 왼쪽 메뉴 **Secrets and variables** → **Actions**
3. **New repository secret** 클릭
4. Name: `KAKAO_REST_KEY`
5. Secret: 3단계에서 복사한 REST API 키 붙여넣기 → Add secret

## 5단계 — GitHub Pages 활성화

1. 저장소 **Settings** → 왼쪽 메뉴 **Pages**
2. Source: **Deploy from a branch**
3. Branch: **main** / 폴더: **/ (root)** → Save
4. 1~2분 기다리면 상단에 배포된 주소가 나와요. 보통 이런 형태:
   ```
   https://<GitHub아이디>.github.io/auction-map/
   ```

## 6단계 — 카카오디벨로퍼스에 이 도메인 등록

1. 카카오디벨로퍼스 → [플랫폼 키] → [JavaScript 키] → JavaScript SDK 도메인
2. 기존에 등록했던 `localhost` 관련 항목들은 지워도 됨
3. **`https://<GitHub아이디>.github.io`** 등록 (뒤에 `/auction-map` 경로는 빼고 도메인까지만)
4. 저장

## 7단계 — Actions 켜기 & 첫 실행

1. 저장소 **Actions** 탭 클릭 → "I understand my workflows, go ahead and enable them" 같은 안내가 뜨면 확인
2. 왼쪽에 **"경매 데이터 자동 업데이트"** 워크플로우 선택
3. 우측 **Run workflow** 버튼으로 **수동 실행** 한 번 해보기 (매일 자동 실행과 별개로 지금 바로 테스트 가능)
4. 몇 분 후 초록 체크가 뜨면 성공 — `data.json`이 최신 데이터로 갱신되고 자동 커밋됨

## 8단계 — 접속 & 홈 화면에 추가

1. `https://<GitHub아이디>.github.io/auction-map/` 접속해서 카카오맵 잘 뜨는지 확인
2. 크롬 메뉴 → **"홈 화면에 추가"** → 아이콘 생성, 앱처럼 실행됨

## 이후 유지보수

- **매일 자동**으로 한국시간 오전 7시에 데이터가 갱신돼요 (워크플로우 파일의 cron 스케줄)
- 스케줄을 바꾸고 싶으면 `.github/workflows/update-data.yml`의 `cron: "0 22 * * *"` 부분 수정 (UTC 기준이라 KST-9시간)
- **스크래퍼가 사이트 구조 변경으로 깨지면**: Actions 탭에서 실패 로그 확인 → `scripts/scrape.py`의 파싱 부분을 실제 페이지 구조에 맞게 조정 필요할 수 있어요. 처음 한 번은 수동 실행해서 결과를 꼭 확인해주세요.
