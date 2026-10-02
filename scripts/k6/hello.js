import http from 'k6/http';
import { check } from 'k6';

const host = __ENV.TARGET_HOST;
const rate = Number(__ENV.RATE || 150);

export const options = {
  hosts: { [host]: __ENV.GATEWAY_IP },
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 100,
      stages: [
        { target: rate, duration: __ENV.RAMP || '1m' },
        { target: rate, duration: __ENV.HOLD || '4m' },
        { target: 0, duration: '30s' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{expected_response:true}': ['p(95)<300'],
    checks: ['rate>0.99'],
  },
  tags: { testid: __ENV.TEST_ID || 'load' },
};

export default function () {
  const res = http.get(`https://${host}/`);
  check(res, { 'status 200': (r) => r.status === 200 });
}
