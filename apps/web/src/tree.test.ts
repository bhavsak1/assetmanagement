import { expect, test } from 'vitest'
import { placeName, placeTitle } from './tree'

const rows = [
  { id: 'p', parent_id: null, name: 'Plant 2' },
  { id: 'b', parent_id: 'p', name: 'Block A' },
  { id: 'u', parent_id: 'b', name: 'Utility Bay' },
]

test('short place: top level · the place; full path as the title', () => {
  expect(placeName(rows, 'u')).toBe('Plant 2 · Utility Bay')
  expect(placeTitle(rows, 'u')).toBe('Plant 2 › Block A › Utility Bay')
  expect(placeName(rows, 'b')).toBe('Plant 2 · Block A')
  expect(placeName(rows, 'p')).toBe('Plant 2')
  expect(placeName(rows, null)).toBe('—')
  expect(placeName(rows, 'gone')).toBe('—')
  expect(placeTitle(rows, null)).toBeUndefined()
})
