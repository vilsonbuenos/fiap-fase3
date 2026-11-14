import http from 'k6/http';
import { sleep } from 'k6';

// Uso: k6 run -e BASE_URL=http://<DNS-DO-ALB> load-tests-k6/teste.js
const BASE_URL = __ENV.BASE_URL || 'http://localhost';
const FLAG = __ENV.FLAG || 'enable-new-dashboard';

export const options = {
  vus: 20,
  duration: __ENV.DURATION || '2m',
};

export default function () {
  const user = `user-${Math.floor(Math.random() * 1000)}`;
  http.get(`${BASE_URL}/evaluation/evaluate?user_id=${user}&flag_name=${FLAG}`);
  sleep(0.2);
}
