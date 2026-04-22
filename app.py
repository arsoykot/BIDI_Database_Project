import os
from flask import Flask, render_template_string, request, redirect, url_for, session
import psycopg

app = Flask(__name__)
app.secret_key = 'bidi-demo-secret'
DB_URL = os.getenv('DATABASE_URL', 'postgresql:///bidi_db')

BASE='''<!doctype html><html><head><title>BiDi Dashboard</title><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:Arial,sans-serif;margin:0;background:#f5f7fb;color:#111827}.wrap{display:grid;grid-template-columns:240px 1fr;min-height:100vh}.side{background:#111827;color:#fff;padding:1.2rem}.side a{display:block;color:#e5e7eb;text-decoration:none;padding:.55rem 0}.main{padding:1.5rem}.card{background:#fff;border-radius:16px;padding:1rem 1.2rem;box-shadow:0 10px 28px rgba(0,0,0,.08);margin-bottom:1rem}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem}.stat{background:#eef2ff;border-radius:14px;padding:1rem}.num{font-size:1.6rem;font-weight:700}.muted{color:#6b7280}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #eee;text-align:left}th{background:#f8fafc}input,select,button{padding:.55rem;border:1px solid #ddd;border-radius:10px}button{cursor:pointer;background:#111827;color:#fff}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}.badge{padding:.2rem .55rem;border-radius:999px;background:#dcfce7}.danger{background:#fee2e2}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem}.card form{display:grid;gap:.75rem}.field{display:grid;gap:.3rem}.actions{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap}</style></head><body><div class='wrap'><div class='side'><h2>BiDi</h2><div class='muted'>Dashboard Panel</div><hr><a href='/'>Dashboard</a><a href='/projects'>Projects</a><a href='/customers'>Customers</a><a href='/employees'>Employees</a><a href='/staffing'>Staffing</a><a href='/audit'>Audit</a><a href='/analytics'>Analytics</a><a href='/login'>Login</a></div><div class='main'>{{content|safe}}</div></div></body></html>'''

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

def set_notice(message, kind='ok'):
    session['notice'] = {'message': message, 'kind': kind}

def pop_notice():
    notice = session.pop('notice', None)
    if not notice:
        return ''
    css = 'card danger' if notice['kind'] == 'error' else 'card'
    return f"<div class='{css}'>{notice['message']}</div>"

@app.route('/')
def home():
    _, p = run('SELECT count(*) FROM bidi.project')
    _, e = run('SELECT count(*) FROM bidi.employee')
    _, c = run('SELECT count(*) FROM bidi.customer')
    _, a = run('SELECT count(*) FROM bidi.project_budget_audit')
    _, w = run('SELECT count(*) FROM bidi.works')
    content=f"<div class='top'><h1>Dashboard</h1><span class='badge'>Live DB</span></div>{pop_notice()}<div class='stats'><div class='stat'><div class='muted'>Projects</div><div class='num'>{p[0][0]}</div></div><div class='stat'><div class='muted'>Employees</div><div class='num'>{e[0][0]}</div></div><div class='stat'><div class='muted'>Customers</div><div class='num'>{c[0][0]}</div></div><div class='stat'><div class='muted'>Assignments</div><div class='num'>{w[0][0]}</div></div><div class='stat'><div class='muted'>Audit Rows</div><div class='num'>{a[0][0]}</div></div></div><div class='card'>Dashboard connected to your PostgreSQL project.</div>"
    return render_template_string(BASE, content=content)

@app.route('/projects', methods=['GET', 'POST'])
def projects():
    if request.method == 'POST':
        action = request.form.get('action')
        try:
            if action == 'create':
                _, rows = run(
                    'INSERT INTO bidi.project(name, budget) VALUES (%s, %s) RETURNING pr_id',
                    (request.form['name'], request.form['budget'])
                )
                project_id = rows[0][0]
                run(
                    'INSERT INTO bidi.commissions(pr_id, cid, start_date, deadline) VALUES (%s, %s, %s, %s)',
                    (project_id, request.form['cid'], request.form['start_date'], request.form['deadline'])
                )
                set_notice(f'Project {project_id} created successfully.')
            elif action == 'budget':
                run(
                    'UPDATE bidi.project SET budget = %s WHERE pr_id = %s',
                    (request.form['budget'], request.form['pr_id'])
                )
                set_notice(f"Budget updated for project {request.form['pr_id']}.")
            elif action == 'delete':
                run('DELETE FROM bidi.project WHERE pr_id = %s', (request.form['pr_id'],))
                set_notice(f"Project {request.form['pr_id']} deleted.")
            else:
                set_notice('Unknown action.', 'error')
        except Exception as ex:
            set_notice(f'Error: {ex}', 'error')
        return redirect(url_for('projects'))

    notice = pop_notice()
    _, customer_rows = run('SELECT cid, name FROM bidi.customer ORDER BY name')
    _, project_rows = run('SELECT pr_id, name, budget FROM bidi.project ORDER BY name')
    customer_options = ''.join(f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in customer_rows)
    project_options = ''.join(f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in project_rows)
    create_form = (
        "<div class='card'><h3>Add Project</h3><form method='post'>"
        "<input type='hidden' name='action' value='create'>"
        "<label class='field'>Project Name <input name='name' required></label>"
        "<label class='field'>Budget <input name='budget' type='number' min='1' step='0.01' required></label>"
        f"<label class='field'>Customer <select name='cid' required>{customer_options}</select></label>"
        "<label class='field'>Start Date <input name='start_date' type='date' required></label>"
        "<label class='field'>Deadline <input name='deadline' type='date' required></label>"
        "<div class='actions'><button>Create Project</button></div></form></div>"
    )
    budget_form = (
        "<div class='card'><h3>Update Budget</h3><form method='post'>"
        "<input type='hidden' name='action' value='budget'>"
        f"<label class='field'>Project <select name='pr_id' required>{project_options}</select></label>"
        "<label class='field'>New Budget <input name='budget' type='number' min='1' step='0.01' required></label>"
        "<div class='actions'><button>Update Budget</button></div></form></div>"
    )
    delete_form = (
        "<div class='card'><h3>Delete Project</h3><form method='post'>"
        "<input type='hidden' name='action' value='delete'>"
        f"<label class='field'>Project <select name='pr_id' required>{project_options}</select></label>"
        "<div class='actions'><button>Delete Project</button></div></form></div>"
    )
    cols, rows = run('SELECT pr_id, project_name, budget, customer_name, customer_email, start_date, deadline FROM bidi.vw_project_overview ORDER BY pr_id')
    return render_template_string(BASE, content='<h1>Projects</h1>'+notice+"<div class='grid'>"+create_form+budget_form+delete_form+"</div>"+table(cols, rows))

@app.route('/customers', methods=['GET', 'POST'])
def customers():
    if request.method == 'POST':
        action = request.form.get('action')
        try:
            if action == 'create':
                run(
                    'INSERT INTO bidi.customer(name, email, lid) VALUES (%s, %s, %s)',
                    (request.form['name'], request.form['email'], request.form['lid'])
                )
                set_notice('Customer created successfully.')
            elif action == 'edit':
                run(
                    'UPDATE bidi.customer SET name = %s, email = %s, lid = %s WHERE cid = %s',
                    (request.form['name'], request.form['email'], request.form['lid'], request.form['cid'])
                )
                set_notice(f"Customer {request.form['cid']} updated.")
            elif action == 'delete':
                run('DELETE FROM bidi.customer WHERE cid = %s', (request.form['cid'],))
                set_notice(f"Customer {request.form['cid']} deleted.")
            else:
                set_notice('Unknown action.', 'error')
        except Exception as ex:
            set_notice(f'Error: {ex}', 'error')
        return redirect(url_for('customers'))

    notice = pop_notice()
    _, location_rows = run('SELECT lid, address, country FROM bidi.location ORDER BY lid')
    _, customer_rows = run('SELECT cid, name FROM bidi.customer ORDER BY name')
    location_options = ''.join(
        f"<option value='{row[0]}'>{row[0]} - {row[1]} ({row[2]})</option>" for row in location_rows
    )
    customer_options = ''.join(f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in customer_rows)
    create_form = (
        "<div class='card'><h3>Add Customer</h3><form method='post'>"
        "<input type='hidden' name='action' value='create'>"
        "<label class='field'>Customer Name <input name='name' required></label>"
        "<label class='field'>Email <input name='email' type='email' required></label>"
        f"<label class='field'>Location <select name='lid' required>{location_options}</select></label>"
        "<div class='actions'><button>Create Customer</button></div></form></div>"
    )
    edit_form = (
        "<div class='card'><h3>Edit Customer</h3><form method='post'>"
        "<input type='hidden' name='action' value='edit'>"
        f"<label class='field'>Customer <select name='cid' required>{customer_options}</select></label>"
        "<label class='field'>New Name <input name='name' required></label>"
        "<label class='field'>New Email <input name='email' type='email' required></label>"
        f"<label class='field'>New Location <select name='lid' required>{location_options}</select></label>"
        "<div class='actions'><button>Save Customer</button></div></form></div>"
    )
    delete_form = (
        "<div class='card'><h3>Delete Customer</h3><form method='post'>"
        "<input type='hidden' name='action' value='delete'>"
        f"<label class='field'>Customer <select name='cid' required>{customer_options}</select></label>"
        "<div class='actions'><button>Delete Customer</button></div></form></div>"
    )
    cols, rows = run("""
        SELECT c.cid, c.name, c.email, l.address, l.country
        FROM bidi.customer c
        JOIN bidi.location l ON l.lid = c.lid
        ORDER BY c.cid
    """)
    return render_template_string(BASE, content='<h1>Customers</h1>'+notice+"<div class='grid'>"+create_form+edit_form+delete_form+"</div>"+table(cols, rows))

@app.route('/employees', methods=['GET', 'POST'])
def employees():
    if request.method == 'POST':
        action = request.form.get('action')
        try:
            if action == 'create':
                run(
                    'INSERT INTO bidi.employee(email, name, dep_id) VALUES (%s, %s, %s)',
                    (request.form['email'], request.form['name'], request.form['dep_id'])
                )
                set_notice('Employee created successfully.')
            elif action == 'edit':
                run(
                    'UPDATE bidi.employee SET name = %s, email = %s, dep_id = %s WHERE emp_id = %s',
                    (request.form['name'], request.form['email'], request.form['dep_id'], request.form['emp_id'])
                )
                set_notice(f"Employee {request.form['emp_id']} updated.")
            elif action == 'delete':
                run('DELETE FROM bidi.employee WHERE emp_id = %s', (request.form['emp_id'],))
                set_notice(f"Employee {request.form['emp_id']} deleted.")
            else:
                set_notice('Unknown action.', 'error')
        except Exception as ex:
            set_notice(f'Error: {ex}', 'error')
        return redirect(url_for('employees'))

    notice = pop_notice()
    _, department_rows = run('SELECT dep_id, name FROM bidi.department ORDER BY name')
    _, employee_rows = run('SELECT emp_id, name FROM bidi.employee ORDER BY name')
    department_options = ''.join(
        f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in department_rows
    )
    employee_options = ''.join(
        f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in employee_rows
    )
    create_form = (
        "<div class='card'><h3>Add Employee</h3><form method='post'>"
        "<input type='hidden' name='action' value='create'>"
        "<label class='field'>Full Name <input name='name' required></label>"
        "<label class='field'>Email <input name='email' type='email' required></label>"
        f"<label class='field'>Department <select name='dep_id' required>{department_options}</select></label>"
        "<div class='actions'><button>Create Employee</button></div></form></div>"
    )
    edit_form = (
        "<div class='card'><h3>Edit Employee</h3><form method='post'>"
        "<input type='hidden' name='action' value='edit'>"
        f"<label class='field'>Employee <select name='emp_id' required>{employee_options}</select></label>"
        "<label class='field'>New Name <input name='name' required></label>"
        "<label class='field'>New Email <input name='email' type='email' required></label>"
        f"<label class='field'>New Department <select name='dep_id' required>{department_options}</select></label>"
        "<div class='actions'><button>Save Employee</button></div></form></div>"
    )
    delete_form = (
        "<div class='card'><h3>Delete Employee</h3><form method='post'>"
        "<input type='hidden' name='action' value='delete'>"
        f"<label class='field'>Employee <select name='emp_id' required>{employee_options}</select></label>"
        "<div class='actions'><button>Delete Employee</button></div></form></div>"
    )
    cols, rows = run("""
        SELECT e.emp_id, e.name, e.email, d.name AS department_name
        FROM bidi.employee e
        JOIN bidi.department d ON d.dep_id = e.dep_id
        ORDER BY e.emp_id
    """)
    return render_template_string(BASE, content='<h1>Employees</h1>'+notice+"<div class='grid'>"+create_form+edit_form+delete_form+"</div>"+table(cols, rows))

@app.route('/staffing', methods=['GET','POST'])
def staffing():
    if request.method=='POST':
        action = request.form.get('action')
        try:
            if action == 'create':
                run('INSERT INTO bidi.works(pr_id, emp_id, started) VALUES (%s,%s,%s)', (request.form['pr_id'], request.form['emp_id'], request.form['started']))
                set_notice('Assignment added successfully.')
            elif action == 'edit':
                run(
                    'UPDATE bidi.works SET started = %s WHERE pr_id = %s AND emp_id = %s',
                    (request.form['started'], request.form['pr_id'], request.form['emp_id'])
                )
                set_notice('Assignment updated successfully.')
            elif action == 'delete':
                run('DELETE FROM bidi.works WHERE pr_id = %s AND emp_id = %s', (request.form['pr_id'], request.form['emp_id']))
                set_notice('Assignment deleted successfully.')
            else:
                set_notice('Unknown action.', 'error')
        except Exception as ex:
            set_notice(f'Error: {ex}', 'error')
        return redirect(url_for('staffing'))

    notice = pop_notice()
    _, project_rows = run('SELECT pr_id, name FROM bidi.project ORDER BY name')
    _, employee_rows = run('SELECT emp_id, name FROM bidi.employee ORDER BY name')
    project_options = ''.join(f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in project_rows)
    employee_options = ''.join(f"<option value='{row[0]}'>{row[0]} - {row[1]}</option>" for row in employee_rows)
    create_form=(
        "<div class='card'><h3>Add Assignment</h3><form method='post'>"
        "<input type='hidden' name='action' value='create'>"
        f"<label class='field'>Project <select name='pr_id' required>{project_options}</select></label>"
        f"<label class='field'>Employee <select name='emp_id' required>{employee_options}</select></label>"
        "<label class='field'>Start Date <input name='started' type='date' required></label>"
        "<div class='actions'><button>Add Assignment</button></div></form></div>"
    )
    edit_form=(
        "<div class='card'><h3>Edit Assignment</h3><form method='post'>"
        "<input type='hidden' name='action' value='edit'>"
        f"<label class='field'>Project <select name='pr_id' required>{project_options}</select></label>"
        f"<label class='field'>Employee <select name='emp_id' required>{employee_options}</select></label>"
        "<label class='field'>New Start Date <input name='started' type='date' required></label>"
        "<div class='actions'><button>Save Assignment</button></div></form></div>"
    )
    delete_form=(
        "<div class='card'><h3>Delete Assignment</h3><form method='post'>"
        "<input type='hidden' name='action' value='delete'>"
        f"<label class='field'>Project <select name='pr_id' required>{project_options}</select></label>"
        f"<label class='field'>Employee <select name='emp_id' required>{employee_options}</select></label>"
        "<div class='actions'><button>Delete Assignment</button></div></form></div>"
    )
    cols, rows = run("""
        SELECT w.pr_id, p.name AS project_name, w.emp_id, e.name AS employee_name, w.started
        FROM bidi.works w
        JOIN bidi.project p ON p.pr_id = w.pr_id
        JOIN bidi.employee e ON e.emp_id = w.emp_id
        ORDER BY w.pr_id, w.emp_id
    """)
    return render_template_string(BASE, content='<h1>Staffing</h1>'+notice+"<div class='grid'>"+create_form+edit_form+delete_form+"</div>"+table(cols, rows))

@app.route('/audit')
def audit():
    cols, rows = run('SELECT audit_id, pr_id, old_budget, new_budget, changed_at, changed_by FROM bidi.project_budget_audit ORDER BY audit_id DESC')
    return render_template_string(BASE, content='<h1>Budget Audit Trail</h1>'+table(cols, rows))

@app.route('/analytics')
def analytics():
    _, budget_rows = run("""
        SELECT
            CASE
                WHEN budget < 100000 THEN 'Under 100k'
                WHEN budget < 250000 THEN '100k-249k'
                ELSE '250k+'
            END AS budget_band,
            count(*)
        FROM bidi.project
        GROUP BY budget_band
        ORDER BY count(*) DESC, budget_band
    """)
    _, staffing_rows = run("""
        SELECT p.name, count(w.emp_id) AS team_size
        FROM bidi.project p
        LEFT JOIN bidi.works w ON w.pr_id = p.pr_id
        GROUP BY p.pr_id, p.name
        ORDER BY team_size DESC, p.name
    """)
    budget_items=''.join(f"<tr><td>{r[0]}</td><td>{r[1]}</td></tr>" for r in budget_rows)
    staffing_items=''.join(f"<tr><td>{r[0]}</td><td>{r[1]}</td></tr>" for r in staffing_rows)
    content=(
        "<h1>Analytics</h1>"
        f"<div class='card'><h3>Project Budget Bands</h3><table><tr><th>Band</th><th>Count</th></tr>{budget_items}</table></div>"
        f"<div class='card'><h3>Project Team Sizes</h3><table><tr><th>Project</th><th>Assigned Employees</th></tr>{staffing_items}</table></div>"
    )
    return render_template_string(BASE, content=content)

@app.route('/login', methods=['GET','POST'])
def login():
    if request.method=='POST':
        user=request.form['user']
        role=request.form['role']
        session['user']=user
        session['role']=role
        set_notice(f'Logged in as {user} ({role})')
        return redirect(url_for('login'))
    msg = pop_notice()
    form="<div class='card'><form method='post'>Name <input name='user'> Role <select name='role'><option>Admin</option><option>Manager</option><option>Customer</option></select> <button>Login</button></form></div>"
    who = session.get('user')
    if who:
        msg += f"<div class='card'>Current session: {who} ({session.get('role')})</div>"
    return render_template_string(BASE, content='<h1>Demo Login</h1>'+msg+form)

if __name__ == '__main__':
    app.run(debug=True)
