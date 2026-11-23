import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateTotals, calculateChange, stockStatus, netSales } from '../src/lib/pos.js';

test('subtotal, discount, tax and total are calculated in integer rupiah', () => {
  assert.deepEqual(calculateTotals([{price:18000,qty:2},{price:10000,qty:1}],5000,true,10), {
    subtotal:46000, discount:5000, tax:4100, total:45100
  });
});

test('discount is clamped and tax is not negative', () => {
  assert.deepEqual(calculateTotals([{price:10000,qty:1}],20000,true,11), {
    subtotal:10000, discount:10000, tax:0, total:0
  });
});

test('cash change never becomes negative', () => {
  assert.equal(calculateChange(50000,42000),8000);
  assert.equal(calculateChange(30000,42000),0);
});

test('stock status handles empty, low and safe stock', () => {
  assert.equal(stockStatus(0,5),'Habis');
  assert.equal(stockStatus(4,5),'Menipis');
  assert.equal(stockStatus(6,5),'Aman');
});

test('net sales exclude tax and reversed transactions', () => {
  assert.equal(netSales({status:'Selesai',subtotal:50000,discount:5000,tax:4950,total:49950}),45000);
  assert.equal(netSales({status:'Refund',subtotal:50000,discount:0,total:50000}),0);
});
