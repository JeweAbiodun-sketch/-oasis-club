-- Corrected welfare contributions seeded from the 23-Apr-2026 statement.
-- Run AFTER 17_welfare_contributions_setup.sql. Idempotent (clears then re-inserts).
begin;
delete from public.welfare_contributions;
delete from public.welfare_events;

insert into public.welfare_events (id,title,type,event_date,target_amount) values
  ('wlf-lv-2223','Welfare Contributions — 2022/2023','levy','2023-02-26',NULL),
  ('wlf-lv-2324','Welfare Contributions — 2023/2024','levy','2024-01-26',NULL),
  ('wlf-lv-2425','Welfare Contributions — 2024/2025','levy','2024-12-18',NULL),
  ('wlf-lv-2526','Welfare Contributions — 2025/2026','levy','2025-12-26',NULL),
  ('wlf-out-1','Issued out to complete the contribution towards Abiodun''s grandma burial','other','2023-04-07',8000),
  ('wlf-out-2','Issued out to Adebayo Lanre for his inlaw burial','other','2023-07-20',20000),
  ('wlf-out-3','Issued out to Olatunde Kunles for his inlaw burial','other','2023-10-02',20000),
  ('wlf-out-4','Issued to Olatude Kunle as Assitance for hosting of AGM','other','2023-12-21',30000),
  ('wlf-out-5','Issued out to Ayodeji Bisi for his brother''s wedding','other','2024-04-21',20000),
  ('wlf-out-6','Adebayo Olanrewaju Father''s burial support','other','2024-10-21',20000),
  ('wlf-out-7','Atolani Femi Accident Hospital Bill Assistance','other','2025-01-02',10000),
  ('wlf-out-8','Issued to Olatude Kunle as extra expenses AGM 2024','other','2025-01-16',16500),
  ('wlf-out-9','Issued to Adebayo Taiwo as his Uncle''s burial support','other','2025-04-27',30000);

insert into public.welfare_contributions (id,event_id,member_id,amount,paid_date) values
  ('wlf-lv-2223-m001','wlf-lv-2223','m001',4000,'2023-08-27'),
  ('wlf-lv-2223-m002','wlf-lv-2223','m002',1000,'2023-04-04'),
  ('wlf-lv-2223-m004','wlf-lv-2223','m004',12000,'2023-03-10'),
  ('wlf-lv-2223-m006','wlf-lv-2223','m006',4000,'2023-04-15'),
  ('wlf-lv-2223-m007','wlf-lv-2223','m007',12000,'2023-08-04'),
  ('wlf-lv-2223-m009','wlf-lv-2223','m009',4000,'2023-05-28'),
  ('wlf-lv-2223-m011','wlf-lv-2223','m011',4000,'2023-04-23'),
  ('wlf-lv-2223-m013','wlf-lv-2223','m013',12000,'2023-02-26'),
  ('wlf-lv-2223-m015','wlf-lv-2223','m015',12000,'2023-03-25'),
  ('wlf-lv-2223-m016','wlf-lv-2223','m016',3000,'2023-04-30'),
  ('wlf-lv-2223-m019','wlf-lv-2223','m019',1000,'2023-05-28'),
  ('wlf-lv-2324-m001','wlf-lv-2324','m001',12000,'2024-05-26'),
  ('wlf-lv-2324-m002','wlf-lv-2324','m002',2500,'2024-07-26'),
  ('wlf-lv-2324-m004','wlf-lv-2324','m004',12000,'2024-06-30'),
  ('wlf-lv-2324-m006','wlf-lv-2324','m006',2000,'2024-05-26'),
  ('wlf-lv-2324-m007','wlf-lv-2324','m007',24000,'2024-09-18'),
  ('wlf-lv-2324-m008','wlf-lv-2324','m008',18000,'2024-09-20'),
  ('wlf-lv-2324-m009','wlf-lv-2324','m009',6000,'2024-06-29'),
  ('wlf-lv-2324-m011','wlf-lv-2324','m011',10000,'2024-09-17'),
  ('wlf-lv-2324-m012','wlf-lv-2324','m012',10000,'2024-06-29'),
  ('wlf-lv-2324-m020','wlf-lv-2324','m020',2000,'2024-04-16'),
  ('wlf-lv-2425-m001','wlf-lv-2425','m001',28000,'2025-07-26'),
  ('wlf-lv-2425-m002','wlf-lv-2425','m002',5000,'2025-08-13'),
  ('wlf-lv-2425-m004','wlf-lv-2425','m004',24000,'2025-02-22'),
  ('wlf-lv-2425-m007','wlf-lv-2425','m007',24000,'2025-07-13'),
  ('wlf-lv-2425-m009','wlf-lv-2425','m009',10000,'2025-02-23'),
  ('wlf-lv-2425-m015','wlf-lv-2425','m015',24000,'2025-02-23'),
  ('wlf-lv-2526-m002','wlf-lv-2526','m002',24000,'2026-03-15'),
  ('wlf-lv-2526-m003','wlf-lv-2526','m003',48000,'2026-03-13'),
  ('wlf-lv-2526-m004','wlf-lv-2526','m004',24000,'2026-03-29'),
  ('wlf-lv-2526-m009','wlf-lv-2526','m009',14000,'2025-12-26');

commit;
notify pgrst, 'reload schema';
