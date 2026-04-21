import os
from flask import Flask, render_template_string, request, redirect, url_for, session
import psycopg
from collections import Counter

app = Flask(__name__)
app.secret_key = 'bidi-demo-secret'
DB_URL = os.getenv('DATABASE_URL', 'postgresql:///bidi_db')

BASE='''<!doctype html><html><head><title>BiDi Advance Dashboard</title><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:Arial,sans-serif;margin:0;background:#f5f7fb;color:#111827}.wrap{display:grid;grid-template-columns:240px 1fr;min-height:100vh}.side{background:#111827;color:#fff;padding:1.2rem}.side a{display:block;color:#e5e7eb;text-decoration:none;padding:.55rem 0}.main{padding:1.5rem}.card{background:#fff;border-radius:16px;padding:1rem 1.2rem;box-shadow:0 10px 28px rgba(0,0,0,.08);margin-bottom:1rem}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem}.stat{background:#eef2ff;border-radius:14px;padding:1rem}.num{font-size:1.6rem;font-weight:700}.muted{color:#6b7280}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #eee;text-align:left}th{background:#f8fafc}input,select,button{padding:.55rem;border:1px solid #ddd;border-radius:10px}button{cursor:pointer;background:#111827;color:#fff}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}.badge{padding:.2rem .55rem;border-radius:999px;background:#dcfce7}.danger{background:#fee2e2}</style></head><body><div class='wrap'><div class='side'><h2>BiDi</h2><div class='muted'>Advance Panel</div><hr><a href='/'>Dashboard</a><a href='/projects'>Projects</a><a href='/staffing'>Staffing</a><a href='/audit'>Audit</a><a href='/analytics'>Analytics</a><a href='/login'>Login</a></div><div class='main'>{{content|safe}}</div></div></body></html>'''

def run(sql, params=None):
    with psycopg.connect(DB_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            if cur.description:
                cols=[d.name for d in cur.description]
                rows=cur.fetchall()
                return cols, rows
            conn.commit(); return [], []

def table(cols, rows):
    if not rows: return "<div class='card'>No rows</div>"
    head=''.join(f'<th>{c}</th>' for c in cols)
    body=''.join('<tr>'+''.join(f'<td>{v}</td>' for v in r)+'</tr>' for r in rows)
    return f"<div class='card'><table><tr>{head}</tr>{body}</table></div>"

@app.route('/')
def home():
    _, p = run('SELECT count(*) FROM bidi.project')
    _, e = run('SELECT count(*) FROM bidi.employee')
    _, c = run('SELECT count(*) FROM bidi.customer')
    _, a = run('SELECT count(*) FROM bidi.project_budget_audit')
    content=f"<div class='top'><h1>Executive Dashboard</h1><span class='badge'>Live DB</span></div><div class='stats'><div class='stat'><div class='muted'>Projects</div><div class='num'>{p[0][0]}</div></div><div class='stat'><div class='muted'>Employees</div><div class='num'>{e[0][0]}</div></div><div class='stat'><div class='muted'>Customers</div><div class='num'>{c[0][0]}</div></div><div class='stat'><div class='muted'>Audit Rows</div><div class='num'>{a[0][0]}</div></div></div><div class='card'>Advance frontend connected to your PostgreSQL project.</div>"
    return render_template_string(BASE, content=content)

@app.route('/projects')
def projects():
    cols, rows = run('SELECT DISTINCT pr_id, project_name, status, budget, customer_name, deadline FROM bidi.vw_project_overview ORDER BY pr_id')
    return render_template_string(BASE, content='<h1>Projects</h1>'+table(cols, rows))

@app.route('/staffing', methods=['GET','POST'])
def staffing():
    msg=''
    if request.method=='POST':
        try:
            run('INSERT INTO bidi.works_on(pr_id, emp_id, allocation_pct) VALUES (%s,%s,%s)', (request.form['pr_id'], request.form['emp_id'], request.form['allocation']))
            msg="<div class='card'>Assignment added successfully.</div>"
        except Exception as ex:
            msg=f"<div class='card danger'>Error: {ex}</div>"
    form="<div class='card'><form method='post'>Project ID <input name='pr_id' required> Employee ID <input name='emp_id' required> Allocation % <input name='allocation' value='25' required> <button>Add Assignment</button></form></div>"
    cols, rows = run('SELECT pr_id, emp_id, allocation_pct, started FROM bidi.works_on ORDER BY pr_id, emp_id')
    return render_template_string(BASE, content='<h1>Staffing</h1>'+msg+form+table(cols, rows))

@app.route('/audit')
def audit():
    cols, rows = run('SELECT audit_id, pr_id, old_budget, new_budget, changed_at, changed_by FROM bidi.project_budget_audit ORDER BY audit_id DESC')
    return render_template_string(BASE, content='<h1>Budget Audit Trail</h1>'+table(cols, rows))

@app.route('/analytics')
def analytics():
    cols, rows = run('SELECT status, count(*) FROM bidi.project GROUP BY status ORDER BY count(*) DESC')
    items=''.join(f"<tr><td>{r[0]}</td><td>{r[1]}</td></tr>" for r in rows)
    card=f"<div class='card'><h3>Project Status Breakdown</h3><table><tr><th>Status</th><th>Count</th></tr>{items}</table></div>"
    return render_template_string(BASE, content='<h1>Analytics</h1>'+card)

@app.route('/login', methods=['GET','POST'])
def login():
    msg=''
    if request.method=='POST':
        user=request.form['user']
        role=request.form['role']
        session['user']=user; session['role']=role
        msg=f"<div class='card'>Logged in as {user} ({role})</div>"
    form="<div class='card'><form method='post'>Name <input name='user'> Role <select name='role'><option>Admin</option><option>Manager</option><option>Customer</option></select> <button>Login</button></form></div>"
    who = session.get('user')
    if who:
        msg += f"<div class='card'>Current session: {who} ({session.get('role')})</div>"
    return render_template_string(BASE, content='<h1>Demo Login</h1>'+msg+form)

if __name__ == '__main__':
    app.run(debug=True)
