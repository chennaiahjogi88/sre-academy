const express = require('express');
const db = require('../db');
const { authenticate } = require('../middleware/auth');
const { classViewsTotal } = require('../metrics');
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const tracer = trace.getTracer('sre-platform-backend');

const router = express.Router();

// All 49 classes definition (class-aws-sd is the new AWS Storage & Database class)
const ALL_CLASSES = [
  { id: 'class-1', module: 'SRE Foundations', title: 'SRE Foundations — Part 1', file: 'sre_foundations_1.html', public: true },
  { id: 'class-2', module: 'SRE Foundations', title: 'SRE Foundations — Part 2', file: 'sre_foundations_2.html', public: true },
  { id: 'class-3', module: 'AWS Cloud', title: 'AWS Basics', file: 'aws_ppt.html', public: false },
  { id: 'class-4', module: 'AWS Cloud', title: 'AWS Compute', file: 'aws_class2.html', public: false },
  { id: 'class-5', module: 'AWS Cloud', title: 'AWS Networking — VPC Basics', file: 'aws_vpc.html', public: false },
  { id: 'class-6', module: 'AWS Cloud', title: 'AWS Networking — Load Balancing', file: 'aws_elb.html', public: false },
  { id: 'class-7', module: 'AWS Cloud', title: 'AWS VPC Deep Dive', file: 'aws_vpc_deep.html', public: false },
  { id: 'class-aws-sd', module: 'AWS Cloud', title: 'AWS Storage & Database', file: 'aws_storage_db.html', public: false },
  { id: 'class-8', module: 'Docker', title: 'Docker Fundamentals', file: 'docker_fundamentals.html', public: false },
  { id: 'class-9', module: 'Docker', title: 'Docker Advanced', file: 'docker_advanced.html', public: false },
  { id: 'class-10', module: 'Docker', title: 'Docker Compose', file: 'docker_compose.html', public: false },
  { id: 'class-11', module: 'Kubernetes', title: 'Kubernetes Basics', file: 'k8s_basics.html', public: false },
  { id: 'class-12', module: 'Kubernetes', title: 'K8s Architecture', file: 'k8s_architecture.html', public: false },
  { id: 'class-13', module: 'Kubernetes', title: 'K8s Scheduling', file: 'k8s_scheduling.html', public: false },
  { id: 'class-14', module: 'Kubernetes', title: 'K8s Reliability Patterns', file: 'k8s_reliability.html', public: false },
  { id: 'class-15', module: 'Kubernetes', title: 'K8s Workloads', file: 'k8s_workloads.html', public: false },
  { id: 'class-16', module: 'Kubernetes', title: 'K8s Scaling', file: 'k8s_scaling.html', public: false },
  { id: 'class-17', module: 'Kubernetes', title: 'Minikube Labs', file: 'minikube.html', public: false },
  { id: 'class-18', module: 'Kubernetes', title: 'K8s Production', file: 'k8s_production.html', public: false },
  { id: 'class-19', module: 'Kubernetes', title: 'Helm Charts', file: 'helm.html', public: false },
  { id: 'class-20', module: 'AWS EKS', title: 'Amazon EKS', file: 'eks.html', public: false },
  { id: 'class-21', module: 'Observability', title: 'Observability Foundations', file: 'observability_intro.html', public: false },
  { id: 'class-23', module: 'Observability', title: 'Prometheus Architecture', file: 'prometheus.html', public: false },
  { id: 'class-24', module: 'Observability', title: 'PromQL & Alerting', file: 'promql.html', public: false },
  { id: 'class-25', module: 'Observability', title: 'Grafana Dashboards', file: 'grafana.html', public: false },
  { id: 'class-26', module: 'Observability', title: 'Grafana Alerts', file: 'grafana_alerts.html', public: false },
  { id: 'class-27', module: 'Observability', title: 'Loki Logging', file: 'loki.html', public: false },
  { id: 'class-28', module: 'Observability', title: 'Distributed Tracing — Jaeger', file: 'jaeger.html', public: false },
  { id: 'class-29', module: 'Observability', title: 'Alertmanager', file: 'alertmanager.html', public: false },
  { id: 'class-30', module: 'IaC', title: 'Terraform Basics', file: 'terraform.html', public: false },
  { id: 'class-31', module: 'Observability', title: 'EKS Observability Stack', file: 'eks_observability.html', public: false },
  { id: 'class-32', module: 'CI/CD', title: 'Git Fundamentals', file: 'git_basics.html', public: false },
  { id: 'class-33', module: 'CI/CD', title: 'GitHub Actions', file: 'github_actions.html', public: false },
  { id: 'class-34', module: 'CI/CD', title: 'GitOps with ArgoCD', file: 'argocd.html', public: false },
  { id: 'class-35', module: 'CI/CD', title: 'Deployment Strategies', file: 'deploy_strategies.html', public: false },
  { id: 'class-36', module: 'SRE Practices', title: 'SLIs, SLOs & SLAs', file: 'sre_metrics.html', public: false },
  { id: 'class-37', module: 'SRE Practices', title: 'Error Budgets', file: 'error_budgets.html', public: false },
  { id: 'class-38', module: 'SRE Practices', title: 'Burn Rate Alerts', file: 'burn_rate.html', public: false },
  { id: 'class-39', module: 'SRE Practices', title: 'Incident Management', file: 'incident_management.html', public: false },
  { id: 'class-40', module: 'SRE Practices', title: 'Incident Command', file: 'incident_command.html', public: false },
  { id: 'class-41', module: 'SRE Practices', title: 'Postmortems & RCA', file: 'postmortems.html', public: false },
  { id: 'class-42', module: 'Advanced', title: 'Capacity Planning', file: 'capacity_planning.html', public: false },
  { id: 'class-43', module: 'Advanced', title: 'Advanced Autoscaling', file: 'autoscaling.html', public: false },
  { id: 'class-44', module: 'Advanced', title: 'Load Testing', file: 'load_testing.html', public: false },
  { id: 'class-45', module: 'Advanced', title: 'Chaos Engineering', file: 'chaos_engineering.html', public: false },
  { id: 'class-46', module: 'Advanced', title: 'Cost Optimization', file: 'cost_optimization.html', public: false },
  { id: 'class-47', module: 'Advanced', title: 'Observability Cost Control', file: 'observability_cost.html', public: false },
  { id: 'class-48', module: 'Advanced', title: 'K8s Security', file: 'k8s_security.html', public: false },
  { id: 'class-49', module: 'Observability', title: 'Observability Masterclass', file: 'observability_class.html', public: false },
];

// GET /api/classes/delivery — get all admin-set delivery statuses
router.get('/delivery', authenticate, async (req, res) => {
  try {
    const result = await db.query('SELECT class_id, status FROM class_delivery_status');
    const statusMap = {};
    result.rows.forEach(r => { statusMap[r.class_id] = r.status; });
    res.json(statusMap);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch delivery status' });
  }
});

// PUT /api/classes/:id/delivery — set delivery status (admin only)
router.put('/:id/delivery', authenticate, async (req, res) => {
  if (req.user.role !== 'admin') return res.status(403).json({ error: 'Admin only' });
  try {
    const { status } = req.body;
    if (!['delivered', 'upcoming'].includes(status)) return res.status(400).json({ error: 'Status must be delivered or upcoming' });
    await db.query(
      `INSERT INTO class_delivery_status (class_id, status, updated_by, updated_at)
       VALUES ($1, $2, $3, NOW())
       ON CONFLICT (class_id) DO UPDATE SET status = $2, updated_by = $3, updated_at = NOW()`,
      [req.params.id, status, req.user.id]
    );
    res.json({ success: true, classId: req.params.id, status });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update delivery status' });
  }
});

// GET /api/classes — returns public classes always, private only if authenticated
router.get('/', (req, res) => {
  const authHeader = req.headers.authorization;
  let isAuth = false;
  let userRole = null;
  if (authHeader) {
    try {
      const jwt = require('jsonwebtoken');
      const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET || 'dev_secret');
      isAuth = true;
      userRole = decoded.role;
    } catch (_) {}
  }
  const classes = isAuth ? ALL_CLASSES : ALL_CLASSES.filter(c => c.public);
  res.json({ classes, isAuthenticated: isAuth, role: userRole });
});

// GET /api/classes/:id/progress — get user progress for a class
router.get('/:id/progress', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      'SELECT * FROM class_progress WHERE user_id = $1 AND class_id = $2',
      [req.user.id, req.params.id]
    );
    res.json(result.rows[0] || { class_id: req.params.id, current_slide: 0, completed: false });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch progress' });
  }
});

// PUT /api/classes/:id/progress — update progress
router.put('/:id/progress', authenticate, async (req, res) => {
  return tracer.startActiveSpan('class.update_progress', async (span) => {
    try {
      const { current_slide, total_slides, completed } = req.body;
      const classId = req.params.id;

      span.setAttributes({
        'class.id': classId,
        'user.id': req.user.id,
        'slide.current': current_slide || 0,
        'slide.total': total_slides || 0,
        'class.completed': completed || false,
      });

      classViewsTotal.inc({ class_id: classId });

      await db.query(
        `INSERT INTO class_progress (user_id, class_id, current_slide, total_slides, completed, last_viewed)
         VALUES ($1, $2, $3, $4, $5, NOW())
         ON CONFLICT (user_id, class_id) DO UPDATE SET
           current_slide = EXCLUDED.current_slide,
           total_slides = EXCLUDED.total_slides,
           completed = EXCLUDED.completed,
           last_viewed = NOW()`,
        [req.user.id, classId, current_slide || 0, total_slides || 0, completed || false]
      );
      span.setStatus({ code: SpanStatusCode.OK });
      span.end();
      res.json({ success: true });
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.end();
      res.status(500).json({ error: 'Failed to update progress' });
    }
  });
});

// GET /api/classes/progress/all — get all progress for current user
router.get('/progress/all', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      'SELECT * FROM class_progress WHERE user_id = $1',
      [req.user.id]
    );
    const progressMap = {};
    result.rows.forEach(r => { progressMap[r.class_id] = r; });
    res.json(progressMap);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch progress' });
  }
});

module.exports = router;
