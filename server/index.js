const express = require('express');
const path = require('path');
const visitorRouter = require('./routes/visitor');
const navRouter = require('./routes/navigation');
const eventRouter = require('./routes/event');
const feedbackRouter = require('./routes/feedback');
const domainsRouter = require('./routes/domains');
const adminRouter = require('./routes/admin');
const protocolRouter = require('./routes/protocol');

const app = express();
app.use(express.json());

app.use('/api/visitor', visitorRouter);
app.use('/api/navigation', navRouter);
app.use('/api/event', eventRouter);
app.use('/api/feedback', feedbackRouter);
app.use('/api/domains', domainsRouter);
app.use('/api/admin', adminRouter);
app.use('/api/protocol', protocolRouter);

app.use(express.static(path.join(__dirname, '..', 'public')));

const port = process.env.PORT || 3000;
const host = process.env.HOST || '0.0.0.0';
app.listen(port, host, () => console.log(`Cognitive Navigator running on http://${host}:${port}`));
