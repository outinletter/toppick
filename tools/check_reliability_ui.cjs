// Render the built dashboard with deterministic fixtures; never trigger collection.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.TOPPICKS_PLAYWRIGHT_PATH || 'playwright-core');
(async () => {
  const html = fs.readFileSync(path.join(__dirname, '../dist/index.html'), 'utf8');
  const item = {code:'000001',name:'검증용 종목',market:'KOSPI',longTermScore:65,
    mediumTerm:{score:65,candidateEligible:true,entryStatus:'conditional-candidate',dataCoveragePct:85,evidenceAsOf:new Date().toISOString(),blockers:[],limitations:[],components:{}},signals:{}};
  const browser = await chromium.launch({headless:true,executablePath:process.env.TOPPICKS_BROWSER_PATH || path.join(process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)','Microsoft/Edge/Application/msedge.exe')});
  try {
    for(const width of [390,1280]) {
      const page = await browser.newPage({viewport:{width,height:900}}); const errors=[];
      page.setDefaultTimeout(10000);
      page.on('pageerror', e=>errors.push(String(e)));
      await page.route('**/*', route=>{
        const url=new URL(route.request().url());
        if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
        if(url.pathname==='/api/recommendations')return route.fulfill({contentType:'application/json',body:JSON.stringify({generatedAt:'synthetic fixture',recommendationDate:'2026-10-02',items:[],top3:[],mediumTerm:{items:[item],formulaVersion:'medium-term-v3-audited'}})});
        if(url.pathname==='/api/medium-learning')return route.fulfill({contentType:'application/json',body:JSON.stringify({generatedAt:new Date().toISOString(),modelsTrained:3,validation:{'20':{brier:0.29,baselineBrier:0.25,nonOverlappingPeriods:5}}})});
        if(url.pathname.startsWith('/api/'))return route.fulfill({status:503,body:'unavailable'});
        return route.abort();
      });
      await page.goto('http://reliability.test/',{waitUntil:'networkidle'});
      const row=page.locator('#longItems .clickrow');
      if(!(await row.innerText()).includes('조건부 후보'))throw Error('Candidate state hidden');
      await page.locator('#researchSection').evaluate(el=>{el.open=true});
      const learning=await page.locator('#mediumLearningStatus').innerText();
      if(!learning.includes('점수 미반영')||!learning.includes('0.290')||!learning.includes('0.250'))throw Error('Learning performance or zero-weight gate hidden');
      await row.click();
      if(errors.length)throw Error(JSON.stringify({width,errors}));
      const body=width===390?page.locator('.mobile-detail-row'):page.locator('#modalBody');
      if(!(await body.innerText()).includes('성과 검증 대기'))throw Error('Validation limitation hidden');
      const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
      if(errors.length||overflow)throw Error(JSON.stringify({width,errors,overflow}));
      const state=await page.evaluate(()=>longEntryState({mediumTerm:{candidateEligible:true,entryStatus:'conditional-candidate',evidenceAsOf:'2020-01-01'}}).label);
      if(state!=='자료 오래됨')throw Error('Stale data promoted');
      console.log(`PASS rendered ${width}px conditional detail, stale gate and no horizontal overflow (synthetic data)`);
      await page.close();
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
