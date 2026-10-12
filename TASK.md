# TASK

> 아래는 이 저장소를 만들 때 받은 지시 내용 원문입니다. (Original task brief, kept verbatim.)

이 저장소에 Oracle → PostgreSQL 이관 데모를 만들어줘. 업워크 포트폴리오용이라 README는 영어로.

시나리오
- 가상 건설사 ERP의 계약 데이터를 Oracle에서 PostgreSQL로 이관
- 테이블: 현장, 계약 헤더, 계약 상세 내역, 발주, 예산
- 실제 회사 데이터는 절대 쓰지 말고 전부 가상 데이터로 생성

구성
- Oracle 원본 스키마 DDL과 PL/SQL 프로시저·함수 몇 개(합계 계산, 상태 변경 등)를 소스로 작성
- PostgreSQL용으로 변환: 데이터 타입 매핑(NUMBER, VARCHAR2, DATE 등), 시퀀스, PL/SQL → PL/pgSQL
- 변환 시 주의점을 문서로 정리 (NVL, DECODE, ROWNUM, 빈 문자열과 NULL 차이 등)
- 이관 스크립트 + 검증 스크립트: 테이블별 건수, 현장 단위 계약금액·발주금액·예산금액 합계가 원본과 같은지 비교
- 이 환경에서 Oracle 실행이 어려우면 Oracle 스크립트는 파일로 제공하고, 검증은 PostgreSQL에 원본 스키마와 대상 스키마를 나눠 시뮬레이션해도 됨
- PostgreSQL 설치도 안 되면 SQLite로 대체 가능. 어떻게 했는지 README에 솔직하게 적을 것

범위 제한
- 데이터는 최대 10만 건, 같은 실험 반복 실행은 3회 이내

마무리
- README에 이관 절차, 타입 매핑 표, 검증 결과 표, 실행 방법 정리
- 이 지시 내용 전체를 TASK.md로 저장
- 브랜치에 push하고 무엇을 만들었는지 요약해줘
