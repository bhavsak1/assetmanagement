import { expect, test } from 'vitest'
import { formatDate, showDate, showDateTime, showDay, showMoney, showNumber } from './format'

const india = { locale: 'en-IN', date_format: 'dd-MM-yyyy', time_zone: 'Asia/Kolkata' }

test('formatDate follows each tenant date format', () => {
  const d = new Date(2026, 2, 5)
  expect(formatDate(d, 'dd-MM-yyyy', 'en-IN')).toBe('05-03-2026')
  expect(formatDate(d, 'MM/dd/yyyy', 'en-US')).toBe('03/05/2026')
  expect(formatDate(d, 'yyyy-MM-dd', 'en-IN')).toBe('2026-03-05')
  expect(formatDate(d, 'dd MMM yyyy', 'en-GB')).toBe('05 Mar 2026')
})

test('showDate: a stored date in the tenant format, no zone shift; raw until the tenant loads', () => {
  expect(showDate('2023-05-06', india)).toBe('06-05-2023')
  expect(showDate('2023-05-06', { locale: 'en-US', date_format: 'MM/dd/yyyy' })).toBe('05/06/2023')
  expect(showDate('2023-05-06', undefined)).toBe('2023-05-06')
  expect(showDate(null, india)).toBe('—')
})

test('showDay and showDateTime: the tenant zone decides the day', () => {
  // 20:00 UTC on 6 May is 01:30 on 7 May in India.
  expect(showDay('2023-05-06T20:00:00Z', india)).toBe('07-05-2023')
  expect(showDay('2023-05-06T20:00:00Z', { ...india, time_zone: 'America/New_York' })).toBe('06-05-2023')
  expect(showDateTime('2023-05-06T20:00:00Z', india)).toMatch(/^07-05-2023 1:30\sam$/i)
})

test('showMoney: en-IN groups lakhs with the rupee sign; other locales their own way', () => {
  expect(showMoney(350000, 'INR', india)).toBe('₹3,50,000')
  expect(showMoney('350000.5', 'INR', india)).toBe('₹3,50,000.50')
  expect(showMoney(350000, 'USD', { locale: 'en-US' })).toBe('$350,000')
  expect(showMoney(350000, 'EUR', { locale: 'de-DE' })).toBe('350.000\u00a0€')
  expect(showMoney(null, 'INR', india)).toBe('—')
  expect(showMoney(1200, null, india)).toBe('1,200')
  // A code Intl rejects still shows.
  expect(showMoney(5, 'X', india)).toBe('5 X')
})

test('showNumber: counts in the tenant locale', () => {
  expect(showNumber(1284000, india)).toBe('12,84,000')
  expect(showNumber(1284000, { locale: 'en-US' })).toBe('1,284,000')
})
