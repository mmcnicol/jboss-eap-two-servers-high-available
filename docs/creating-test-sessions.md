# Creating lots of user sessions

How to create large numbers of realistic user sessions (e.g. 1,000) for HA,
passivation and load testing, using Selenium and k6.

See also: [HA session replication test plan](ha-session-replication-test-plan.md)
and [CI session serialization check](ci-serialization-check.md).

## A session stays on the server after the client goes away

A session lives in JBoss until it times out, whether or not any browser or
virtual user is still attached. So to get 1,000 sessions you don't need 1,000
browsers or 1,000 virtual users running at once. You need 1,000 **separate
cookie jars**, each logged in and taken through the flow, all within the session
timeout.

- **Selenium:** keep a small number of browsers (e.g. 10), but loop inside each
  one. Run the flow, call `driver.manage().deleteAllCookies()`, and run it
  again. Each loop creates a new server-side session.
- **k6:** by default, k6 clears each virtual user's cookies at the end of every
  iteration. So `iterations: 1000` with around 20 virtual users gives 1,000
  separate sessions quickly.

Check the timing. For example, a 20-second Selenium flow on 10 browsers takes
about 33 minutes to create 1,000 sessions. If the session timeout is 30 minutes,
the first sessions expire before the last ones exist. Either speed the flow up
or raise the timeout in UAT for the test.

## Use Selenium and k6 for different jobs

| | Selenium | k6 (HTTP level) |
| --- | --- | --- |
| Cost per session | A real browser, roughly 200–500 MB each | Very small; thousands are fine |
| Realism | Runs JavaScript, so all AJAX calls happen | Only sends the requests you script |
| Best for | A few realistic sessions, to calibrate against | Volume |

A difference between sessions created by Selenium and by k6 is most likely
because **k6 doesn't run JavaScript**. JSF/PrimeFaces pages often make AJAX calls
after the page loads, for lazy data tables, `remoteCommand` and tab loading.
Those calls create and populate view beans. A k6 script without them produces
smaller, unrealistic sessions.

A second common cause is JSF returning **HTTP 200 with an error page** or
`ViewExpiredException`. A k6 script that only checks the status code reports
success when the login or postback actually failed.

To bring the two in line:

1. Record the Selenium flow's network traffic as a HAR file (browser DevTools →
   Network → Save as HAR). Convert it to a k6 script with Grafana k6 Studio or
   the HAR converter, so the AJAX calls are included.
2. In k6, take `javax.faces.ViewState` from every response and send it with the
   next POST. AJAX requests also need the `Faces-Request: partial/ajax` header
   and the `javax.faces.partial.*` parameters.
3. Check page **content**, such as the patient name or a logout link, not just
   the status code.
4. **Calibrate:** create around 50 sessions with Selenium and 50 with k6, then
   compare the average session size. If k6's sessions are much smaller, the
   script is still missing requests.

### k6 starting point

The form field names are placeholders, but fixed component IDs make them stable.

```js
import http from 'k6/http';
import { check } from 'k6';
import { parseHTML } from 'k6/html';
import exec from 'k6/execution';

export const options = {
  scenarios: {
    fill: { executor: 'shared-iterations', vus: 20, iterations: 1000, maxDuration: '25m' },
  },
};

const users = JSON.parse(open('./users.json'));
const BASE = __ENV.BASE_URL;
const viewState = (res) =>
  parseHTML(res.body).find('input[name="javax.faces.ViewState"]').first().attr('value');

export default function () {
  const user = users[exec.scenario.iterationInTest % users.length];
  let res = http.get(`${BASE}/login.xhtml`);
  res = http.post(`${BASE}/login.xhtml`, {
    'loginForm': 'loginForm',
    'loginForm:username': user.username,
    'loginForm:password': user.password,
    'loginForm:loginButton': '',
    'javax.faces.ViewState': viewState(res),
  });
  check(res, { 'logged in': (r) => r.body.includes('Logout') });
  // patient quick search, then patient-context pages,
  // each POST using viewState() from the previous response
}
```

## Using a single username is risky

- **The duplicate-login logic may skew the results.** If a second login with the
  same username invalidates or blocks the first session, you may end up with
  far fewer live sessions than the test tool reports. Find out how the check
  works. If it's server-side (e.g. an application-wide map of username to
  session), it will interfere with the test. If it's client-side, such as tab
  detection in the browser, separate browsers and k6 won't trigger it.
- **It's unrealistic in other ways.** A single user means lock contention and
  auditing on one user record, and every session hitting the same user-level
  caches.
- **Ask for bulk test accounts in UAT**, e.g. 200–1,000 users, and cycle through
  them as in `users.json` above.
- **Vary the patients too.** If every session searches for the same patient, the
  Data Grid hit rate is 100%. That understates the load on the Data Grid and
  the external APIs.

## Login-page-only sessions

A GET of the login page does create a session, because JSF stores the login
view's state in it, but that session is small. After login, the page template
creates many view beans, so realistic memory use and serialization errors only
show up after login. Login-page-only sessions are still useful as a cheap first
tier:

| Tier | How | Use it to test |
| --- | --- | --- |
| 1. Empty sessions | GET the login page only | Session-count limits and passivation triggering, quickly; the baseline memory per session |
| 2. Full sessions | k6: login → patient search → 3–5 patient-context pages | Realistic memory, replication volume, and serialization errors |
| 3. Realistic sessions | A few Selenium browsers | Checking that the k6 sessions are realistic |

Tier 2 is what matters for HA.

## Check the server's session count, not the tool's

Trust what JBoss reports:

- Active sessions per node:
  `/deployment=app.war/subsystem=undertow:read-resource(include-runtime=true)`.
  This also shows whether mod_cluster split the sessions across both nodes.
- Rough session size: heap used after a full GC, before and after creating the
  sessions, divided by the number of sessions.

## A test order that works

1. Fill with around 1,000 full sessions using k6 (tier 2).
2. Run steady load on a subset of them, e.g. 10–20%. Holding sessions and
   actively using them are separate things, and 1,000 sessions doesn't mean
   1,000 active users.
3. Fail a node while the steady load runs, then compare the surviving node's
   session count with the total before the failure.
