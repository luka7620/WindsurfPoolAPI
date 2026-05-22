import { createHmac, timingSafeEqual } from 'crypto';
import { config } from './config.js';

const ADMIN_COOKIE = 'windsurf_admin';
const ADMIN_COOKIE_MAX_AGE = 7 * 24 * 60 * 60;

export function getAdminCredential() {
  return config.dashboardPassword || config.apiKey || '';
}

export function isAdminAuthConfigured() {
  return !!getAdminCredential();
}

function firstHeader(value) {
  if (Array.isArray(value)) return value[0] || '';
  return typeof value === 'string' ? value : '';
}

export function extractAdminToken(req) {
  const dashboardPassword = firstHeader(req.headers['x-dashboard-password']);
  if (dashboardPassword) return dashboardPassword;

  const xApiKey = firstHeader(req.headers['x-api-key']);
  if (xApiKey) return xApiKey;

  const authorization = firstHeader(req.headers.authorization);
  if (authorization.startsWith('Bearer ')) return authorization.slice(7);
  return authorization;
}

function parseCookies(req) {
  const cookieHeader = firstHeader(req.headers.cookie);
  const cookies = {};
  for (const part of cookieHeader.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const key = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim();
    if (!key) continue;
    try {
      cookies[key] = decodeURIComponent(value);
    } catch {
      cookies[key] = value;
    }
  }
  return cookies;
}

function adminCookieValue() {
  const credential = getAdminCredential();
  if (!credential) return '';
  return createHmac('sha256', credential)
    .update('windsurf-admin-session:v1')
    .digest('base64url');
}

export function createAdminSessionCookie() {
  const value = encodeURIComponent(adminCookieValue());
  return `${ADMIN_COOKIE}=${value}; Path=/; Max-Age=${ADMIN_COOKIE_MAX_AGE}; HttpOnly; SameSite=Strict`;
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a || ''));
  const right = Buffer.from(String(b || ''));
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function validateAdminRequest(req) {
  const credential = getAdminCredential();
  if (!credential) return false;
  if (safeEqual(extractAdminToken(req), credential)) return true;

  const cookieToken = parseCookies(req)[ADMIN_COOKIE] || '';
  return safeEqual(cookieToken, adminCookieValue());
}

export function adminAuthFailure() {
  if (!isAdminAuthConfigured()) {
    return {
      status: 403,
      body: {
        error: 'Admin authentication is not configured. Set DASHBOARD_PASSWORD, or set API_KEY as a fallback.',
      },
    };
  }
  return {
    status: 401,
    body: { error: 'Unauthorized. Set X-Dashboard-Password, Authorization: Bearer, or x-api-key.' },
  };
}
